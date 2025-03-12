--- (1) create portfolio table ---

CREATE TABLE portfolio (
    key_policy int,
    sales_date date,
    key_ss_org int,
    payment_date date,
    payment_status varchar(255),
    annual_premium numeric,
    cancel_before_vid_fm int,
    cancel_after_vid_fm int,
    product_name varchar(255),
    no_of_sold_policies int,
    no_of_cancelled_policies int,
    no_of_paid_policies int,
    vld_fm_tms timestamp,
    vld_to_tms timestamp
);

--- (2) create policy table ----

CREATE TABLE policy (
    key_policy int,
    ext_refr varchar(255),
    term int,
    vrsn int,
    sub_vrsn int,
    incp_dt date,
    bnd_dt date,
    pln_end_dt date,
    renew_dt date,
    cncl_dt date,
    sts_dt date,
    agrm_sts_cd varchar(255),
    prtn varchar(255),
    vld_fm_tms timestamp,
    vld_to_tms timestamp
);

--- (3) create transactions table ----

CREATE TABLE transactions (
    pev_created_at timestamp,
    pev_portfolio_responsible_code varchar(255),
    po_no varchar(255),
    pev_id int
);

--- (4) create sales table ----

CREATE TABLE sales (
    key_ss_org int,
    fld_rep_cd varchar(255),
    org_lvl_cd varchar(255),
    org_lvl_nm varchar(255)
);

--- test to see if data was loaded correctly ----
