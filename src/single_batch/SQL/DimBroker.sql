-- Databricks notebook source
CREATE OR REPLACE TABLE IDENTIFIER(:catalog || '.' || :wh_db || '_' || :scale_factor || '.DimBroker') (
  ${tgt_schema}
  ${constraints}
)
TBLPROPERTIES (${tbl_props});

-- COMMAND ----------

INSERT OVERWRITE IDENTIFIER(:catalog || '.' || :wh_db || '_' || :scale_factor || '.DimBroker')
SELECT
  employeeid sk_brokerid,
  employeeid brokerid,
  managerid,
  employeefirstname firstname,
  employeelastname lastname,
  employeemi middleinitial,
  employeebranch branch,
  employeeoffice office,
  employeephone phone,
  true iscurrent,
  1 batchid,
  (
    SELECT min(to_date(datevalue)) as effectivedate 
    FROM IDENTIFIER(:catalog || '.' || :wh_db || '_' || :scale_factor || '.DimDate')
  ) effectivedate,
  date('9999-12-31') enddate
FROM read_files(
  "${tpcdi_directory}sf=${scale_factor}/Batch1",
  format => "csv",
  inferSchema => False, 
  header => False,
  sep => ",",
  fileNamePattern => "HR.csv", 
  schemaEvolutionMode => 'none',
  schema => "employeeid BIGINT, managerid BIGINT, employeefirstname STRING, employeelastname STRING, employeemi STRING, employeejobcode STRING , employeebranch STRING, employeeoffice STRING, employeephone STRING"
)
WHERE employeejobcode = 314;
