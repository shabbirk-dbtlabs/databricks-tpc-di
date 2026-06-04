-- Singular test example.
-- Every company in DimCompany should have exactly one current (iscurrent = true)
-- version. This catches both missing-current and duplicate-current bugs in the
-- SCD2 close-out logic.
-- The test passes when zero rows are returned.

select
    companyid,
    count_if(iscurrent) as current_versions
from {{ ref('DimCompany') }}
group by companyid
having count_if(iscurrent) <> 1
