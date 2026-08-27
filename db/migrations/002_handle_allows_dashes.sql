-- Allow dashes in handles.
--
-- The original rule was [a-z0-9_]{3,24}, which rejects the perfectly ordinary
-- "drift-wood". The shape is enforced in two places - Zod at the edge and this
-- check constraint - so relaxing only the API would turn a validation message
-- into a 500 at insert time.

alter table users drop constraint if exists handle_shape;

alter table users
    add constraint handle_shape check (handle ~ '^[a-z0-9_-]{3,24}$');
