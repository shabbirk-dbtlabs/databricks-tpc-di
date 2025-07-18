-- Databricks notebook source
USE IDENTIFIER(:catalog || '.' || :wh_db || '_' || :scale_factor);
CREATE OR REPLACE TABLE FactMarketHistory (
  ${tgt_schema}
  ${constraints}
)
TBLPROPERTIES (${tbl_props});

-- COMMAND ----------

INSERT OVERWRITE IDENTIFIER(:catalog || '.' || :wh_db || '_' || :scale_factor || '.FactMarketHistory')
WITH companyfinancials as (
  SELECT
    f.sk_companyid,
    fi_qtr_start_date,
    sum(fi_basic_eps) OVER (PARTITION BY companyid ORDER BY fi_qtr_start_date ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) - fi_basic_eps sum_fi_basic_eps
  FROM IDENTIFIER(:catalog || '.' || :wh_db || '_' || :scale_factor || '.Financial') f
  JOIN IDENTIFIER(:catalog || '.' || :wh_db || '_' || :scale_factor || '.DimCompany') d
    on f.sk_companyid = d.sk_companyid
),
dailymarket as (
  SELECT
    *,
    1 batchid
  FROM read_files(
    "${tpcdi_directory}sf=${scale_factor}/Batch1",
    format => "csv",
    inferSchema => False,
    header => False,
    sep => "|",
    fileNamePattern => "DailyMarket.txt",
    schemaEvolutionMode => 'none',
    schema => "dm_date DATE, dm_s_symb STRING, dm_close DOUBLE, dm_high DOUBLE, dm_low DOUBLE, dm_vol INT"
  )
  UNION ALL
  SELECT
    * except(cdc_flag, cdc_dsn),
    int(substring(_metadata.file_path FROM (position('/Batch', _metadata.file_path) + 6) FOR 1)) batchid
  FROM read_files(
    "${tpcdi_directory}sf=${scale_factor}/Batch{2,3}",
    format => "csv",
    inferSchema => False,
    header => False,
    sep => "|",
    fileNamePattern => "DailyMarket.txt",
    schemaEvolutionMode => 'none',
    schema => "cdc_flag STRING, cdc_dsn BIGINT, dm_date DATE, dm_s_symb STRING, dm_close DOUBLE, dm_high DOUBLE, dm_low DOUBLE, dm_vol INT"
  )
),
markethistory as (
  SELECT
    dm.*,
    min_by(struct(dm_low, dm_date), dm_low) OVER (
      PARTITION BY dm_s_symb
      ORDER BY dm_date ASC 
      --RANGE BETWEEN INTERVAL '1' YEAR PRECEDING 
      ROWS BETWEEN 364 PRECEDING 
      AND CURRENT ROW
    ) fiftytwoweeklow,
    max_by(struct(dm_high, dm_date), dm_high) OVER (
      PARTITION by dm_s_symb
      ORDER BY dm_date ASC 
      --RANGE BETWEEN INTERVAL '1' YEAR PRECEDING 
      ROWS BETWEEN 364 PRECEDING 
      AND CURRENT ROW
    ) fiftytwoweekhigh
  FROM dailymarket dm
)
select
  s.sk_securityid,
  s.sk_companyid,
  bigint(date_format(dm_date, 'yyyyMMdd')) sk_dateid,
  try_divide(mh.dm_close, sum_fi_basic_eps) AS peratio,
  (try_divide(s.dividend, mh.dm_close)) / 100 yield,
  fiftytwoweekhigh.dm_high fiftytwoweekhigh,
  bigint(date_format(fiftytwoweekhigh.dm_date, 'yyyyMMdd')) sk_fiftytwoweekhighdate,
  fiftytwoweeklow.dm_low fiftytwoweeklow,
  bigint(date_format(fiftytwoweeklow.dm_date, 'yyyyMMdd')) sk_fiftytwoweeklowdate,
  dm_close closeprice,
  dm_high dayhigh,
  dm_low daylow,
  dm_vol volume,
  mh.batchid
FROM markethistory mh
JOIN IDENTIFIER(:catalog || '.' || :wh_db || '_' || :scale_factor || '.DimSecurity') s 
  ON 
    s.symbol = mh.dm_s_symb
    AND mh.dm_date >= s.effectivedate 
    AND mh.dm_date < s.enddate
LEFT JOIN companyfinancials f 
  ON 
    f.sk_companyid = s.sk_companyid
    AND quarter(mh.dm_date) = quarter(fi_qtr_start_date)
    AND year(mh.dm_date) = year(fi_qtr_start_date)
