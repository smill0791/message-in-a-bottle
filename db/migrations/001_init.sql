-- Message in a Bottle - initial schema
--
-- Design notes:
--   * Every table a user can grow is keyed by uuid, so ids leak no ordering
--     or volume information.
--   * `discoveries` carries the uniqueness constraint that makes the core
--     product rule enforceable in the database rather than the application:
--     a user never finds the same bottle twice.
--   * `message_stats` is deliberately denormalized. The discovery query is the
--     hot path and must not aggregate ratings at read time.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- users
-- ---------------------------------------------------------------------------

create table users (
    id            uuid primary key default gen_random_uuid(),
    handle        text        not null unique,
    password_hash text        not null,
    created_at    timestamptz not null default now(),

    constraint handle_shape check (handle ~ '^[a-z0-9_]{3,24}$')
);

-- Sessions live in Postgres, not in app memory. This is what keeps the app
-- tier stateless and the Auto Scaling group meaningful.
create table sessions (
    token      text        primary key,
    user_id    uuid        not null references users (id) on delete cascade,
    created_at timestamptz not null default now(),
    expires_at timestamptz not null
);

create index sessions_user_idx on sessions (user_id);
create index sessions_expiry_idx on sessions (expires_at);

-- ---------------------------------------------------------------------------
-- messages
-- ---------------------------------------------------------------------------

create type message_status as enum ('pending', 'approved', 'rejected');

create table messages (
    id         uuid           not null primary key default gen_random_uuid(),
    author_id  uuid           not null references users (id) on delete cascade,
    body       text           not null,
    status     message_status not null default 'pending',
    created_at timestamptz    not null default now(),

    -- Long enough for a real thought, short enough to feel handwritten.
    constraint body_length check (char_length(body) between 1 and 500)
);

-- The discovery query filters on status and excludes the reader's own work,
-- so both belong in the index that serves it.
create index messages_pool_idx on messages (status, author_id) where status = 'approved';

-- ---------------------------------------------------------------------------
-- discoveries - the many-to-many at the heart of the product
-- ---------------------------------------------------------------------------

create table discoveries (
    id            uuid        not null primary key default gen_random_uuid(),
    user_id       uuid        not null references users (id) on delete cascade,
    message_id    uuid        not null references messages (id) on delete cascade,
    discovered_at timestamptz not null default now(),
    saved         boolean     not null default false,
    favorited     boolean     not null default false,

    -- A bottle is found once. This is the rule the whole app rests on.
    unique (user_id, message_id)
);

-- Serves the "exclude what I've already seen" anti-join.
create index discoveries_user_message_idx on discoveries (user_id, message_id);

-- Serves the chest view.
create index discoveries_chest_idx on discoveries (user_id, discovered_at desc)
    where saved = true;

-- ---------------------------------------------------------------------------
-- ratings
-- ---------------------------------------------------------------------------

-- Theme, not quality. "Sad" is not a downvote - life is sometimes sad, and a
-- reflective message about hardship is exactly what this app is for.
create type message_theme as enum (
    'encouraging',
    'uplifting',
    'reflective',
    'grateful',
    'hopeful',
    'sad'
);

create table ratings (
    user_id    uuid          not null references users (id) on delete cascade,
    message_id uuid          not null references messages (id) on delete cascade,
    theme      message_theme not null,
    resonated  boolean       not null default false,
    created_at timestamptz   not null default now(),

    primary key (user_id, message_id)
);

create index ratings_message_idx on ratings (message_id);

-- ---------------------------------------------------------------------------
-- reports
-- ---------------------------------------------------------------------------

create type report_reason as enum ('hateful', 'spam', 'harassment', 'off_vibe', 'other');

create table reports (
    id          uuid          not null primary key default gen_random_uuid(),
    reporter_id uuid          not null references users (id) on delete cascade,
    message_id  uuid          not null references messages (id) on delete cascade,
    reason      report_reason not null,
    note        text,
    resolved    boolean       not null default false,
    created_at  timestamptz   not null default now(),

    unique (reporter_id, message_id)
);

create index reports_open_idx on reports (message_id) where resolved = false;

-- ---------------------------------------------------------------------------
-- message_stats - denormalized discovery weight
-- ---------------------------------------------------------------------------

create table message_stats (
    message_id      uuid             not null primary key
                        references messages (id) on delete cascade,
    discovery_count integer          not null default 0,
    rating_count    integer          not null default 0,
    resonated_count integer          not null default 0,
    report_count    integer          not null default 0,
    weight          double precision not null default 1.0,
    updated_at      timestamptz      not null default now(),

    constraint weight_positive check (weight > 0)
);

-- The discovery query samples on weight. Without this index it degrades to a
-- sequential scan of the whole pool.
create index message_stats_weight_idx on message_stats (weight desc);
