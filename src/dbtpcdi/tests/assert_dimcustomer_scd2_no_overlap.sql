-- Singular test example.
-- For a slowly-changing (type 2) dimension, the effective windows for a given
-- natural key must not overlap. This finds any customer whose record windows
-- overlap (the next version starts before the current one ends).
-- The test passes when zero rows are returned.

with versions as (
    select
        customerid,
        effectivedate,
        enddate,
        lead(effectivedate) over (
            partition by customerid
            order by effectivedate
        ) as next_effectivedate
    from {{ ref('DimCustomer') }}
)

select
    customerid,
    effectivedate,
    enddate,
    next_effectivedate
from versions
where next_effectivedate is not null
  and next_effectivedate < enddate
