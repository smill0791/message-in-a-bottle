-- Moderation: who can review, and an audit trail of what they decided.

-- A boolean rather than a roles table. There is one operator today and a
-- general-purpose permission system would be machinery in search of a problem.
-- If a second kind of privilege ever appears, that is the moment to build it.
alter table users
    add column is_moderator boolean not null default false;

-- Who decided, and when. Without this there is no way to tell an unreviewed
-- message from one a moderator deliberately left pending.
alter table messages
    add column moderated_at timestamptz,
    add column moderated_by uuid references users (id);

-- The review queue reads pending messages oldest-first, constantly.
create index messages_queue_idx on messages (status, created_at)
    where status = 'pending';

-- Report resolution is what makes a moderator's decision stick. Auto-pull
-- counts *unresolved* reports, so approving a reported message and clearing
-- its reports means the next single report cannot immediately re-pull it.
create index reports_unresolved_idx on reports (message_id)
    where resolved = false;
