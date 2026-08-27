#!/usr/bin/env bash
# Put placeholder bottles on the beach so there is something to open locally.
#
# These are stand-ins. The real seed set - the messages that set the tone for
# every new arrival - is Sampson's to write.
#
# Safe to re-run: it clears the seed author's messages first.

set -euo pipefail

SEED_AUTHOR='99999999-9999-9999-9999-999999999999'

docker exec -i bottle-db psql -U bottle -d bottle -v ON_ERROR_STOP=1 -q <<SQL
delete from messages where author_id = '$SEED_AUTHOR';

insert into users (id, handle, password_hash)
values ('$SEED_AUTHOR', 'tide', 'scrypt\$00\$00')
on conflict (id) do nothing;

with seed(body) as (values
  ('Some days the tide goes out further than you expect. It always comes back.'),
  ('I was certain I had ruined everything. Two years on, I can barely remember why.'),
  ('You do not have to be doing well to be doing enough.'),
  ('The thing I was most afraid of turned out to be survivable, and quite boring.'),
  ('Nobody is thinking about it as much as you are. I promise.'),
  ('It is alright to miss something that was bad for you.'),
  ('I planted bulbs the winter I felt worst. In spring they came up anyway.')
)
insert into messages (author_id, body, status)
select '$SEED_AUTHOR', body, 'approved' from seed;

insert into message_stats (message_id)
select id from messages
where not exists (select 1 from message_stats s where s.message_id = messages.id);
SQL

count=$(docker exec bottle-db psql -U bottle -d bottle -qtA \
    -c "select count(*) from messages where status='approved'" | tr -d ' \n')
echo "approved bottles on the beach: $count"
