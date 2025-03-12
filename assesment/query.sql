-- Define monthly report start and end date
SET
    -- First day of January 2024
    REPORT_START_DATE = DATE('2024-01-01');
SET
    -- Last day of August 2024
    REPORT_END_DATE = DATE('2024-08-31');

WITH
    -- Find all policies that meet criteria 1 and 2
    ELIGIBLE_POLICY_TRANSACTION_ENTRIES AS (
        SELECT
            PO_NO AS POLICY_NUMBER,
            -- Get the portfolio responsible code for each policy
            -- (use MIN since all values are identical within a policy)
            MIN(PEV_PORTFOLIORESPONSIBLECODE) AS RESPONSIBLE_CODE
        FROM
            POLICY_TRANSACTIONS
        GROUP BY
            PO_NO
        HAVING
            -- Criterion 2: Responsible Code should not have changed
            -- during policy lifetime
            COUNT(DISTINCT PEV_PORTFOLIORESPONSIBLECODE) = 1
            -- Criterion 1: The policies have been marked with the
            -- portfolio code as 'WILDWEST-2' or 'WILDWEST-3'
            AND RESPONSIBLE_CODE IN ('WILDWEST-2', 'WILDWEST-3')
    ),

    -- Find all canceled policies
    CANCELED_POLICIES AS (
        SELECT
            EXT_REFR,
            -- Use earliest cancellation date
            MIN(CNCL_DT) AS CANCEL_DATE
        FROM
            POLICY
        WHERE CNCL_DT IS NOT NULL
        GROUP BY EXT_REFR
    ),

    -- Find all policies that meet criteria 3 and 4
    ELIGIBLE_PORTFOLIO_ENTRIES AS (
        SELECT
            *
        FROM
            PORTFOLIO
        WHERE
            -- Criterion 3: Only include policies where the premium was paid
            PAYMENT_STATUS = 'Paid'
            AND
            -- Criterion 4: Only include 'Product 1' through 'Product 8' and
            -- 'Product 13' through 'Product 31'
            (
                (
                    CAST(SUBSTRING(PRODUCT_NAME, 8) AS INT) BETWEEN 1 AND 8
                )
                OR (
                    CAST(SUBSTRING(PRODUCT_NAME, 8) AS INT) BETWEEN 13 AND 31
                )
            )
    ),

     -- Join all tables and find all policies that meet criterion 5
    ALL_ELIGIBLE_POLICIES AS (
        SELECT
            POLICY.KEY_POLICY,
            POLICY.EXT_REFR,
            ELIGIBLE_PORTFOLIO_ENTRIES.PAYMENT_STATUS,
            ELIGIBLE_PORTFOLIO_ENTRIES.VLD_FM_TMS AS VALID_FROM,
            ELIGIBLE_PORTFOLIO_ENTRIES.VLD_TO_TMS AS VALID_TO,
            ELIGIBLE_PORTFOLIO_ENTRIES.ANNUAL_PREMIUM,
            ELIGIBLE_PORTFOLIO_ENTRIES.SALES_DATE,
            CANCELED_POLICIES.CANCEL_DATE
        FROM
            POLICY
        -- Get portfolio responsible code
        INNER JOIN ELIGIBLE_POLICY_TRANSACTION_ENTRIES
                ON ELIGIBLE_POLICY_TRANSACTION_ENTRIES.POLICY_NUMBER = POLICY.EXT_REFR
        -- Get sales date, annual premium and validity period for sales
        -- (exclude renewals and other transactions)
        INNER JOIN ELIGIBLE_PORTFOLIO_ENTRIES
                ON ELIGIBLE_PORTFOLIO_ENTRIES.KEY_POLICY = POLICY.KEY_POLICY
        -- Add sales channel
        INNER JOIN SALES_ORG
                ON SALES_ORG.KEY_SS_ORG = ELIGIBLE_PORTFOLIO_ENTRIES.KEY_SS_ORG
        -- Add cancellation date for each Policy Number if it was ever canceled
        LEFT JOIN CANCELED_POLICIES
                ON CANCELED_POLICIES.EXT_REFR = POLICY.EXT_REFR
        WHERE
            -- Criterion 5:
            -- Only include sales that fulfill the Outbound/Wildwest-3,
            -- Internet/Wildwest-3 and Inbound/Wildwest-2 combinations
            -- for Sales Channel/Portfolio Responsible Code
            (
                (
                    ORG_LVL_NM IN ('Outbound', 'Internet')
                    AND RESPONSIBLE_CODE = 'WILDWEST-3'
                )
                OR (
                    ORG_LVL_NM IN ('Inbound')
                    AND RESPONSIBLE_CODE = 'WILDWEST-2'
                )
            )

    ),

    -- Rank policies and calculate their commissions and clawbacks
    ALL_ELIGIBLE_POLICIES_WITH_COMMISSION AS (
        SELECT
            -- Select relevant dates and alias them from readability
            KEY_POLICY,
            EXT_REFR,
            VALID_FROM,
            VALID_TO,
            SALES_DATE,
            CANCEL_DATE,
            PAYMENT_STATUS,
            -- Rank policies by the date when they start being effective
            ROW_NUMBER() OVER (ORDER BY SALES_DATE) AS COMMISSION_RANK,
            -- Calculate a 12% commission for the first 1,500 policies, and
            -- 14% for policies from the 1,501st onward
            IFF(COMMISSION_RANK <= 1500, 0.12, 0.14) * ANNUAL_PREMIUM AS COMMISSION,
            -- Calculate clawback
            -- Find policy sales (KEY_POLICY) that got canceled
            IFF(
                CANCEL_DATE BETWEEN VALID_FROM AND VALID_TO,
                -- Calculate clawback:
                -- Commission / policy active months (commission per month)
                COMMISSION / ABS(DATEDIFF(MONTH, VALID_FROM, VALID_TO)) *
                -- Months between the cancellation and planned end date, with a notice
                -- period of 1 month (inactive months)
                (ABS(DATEDIFF(MONTH, VALID_TO, CANCEL_DATE)) - 1),
                -- If policy sale is not cancelled clawback is 0
                0
            ) AS RAW_CLAWBACK,
                IFF(RAW_CLAWBACK >= 0, RAW_CLAWBACK, 0) AS CLAWBACK
        FROM
            ALL_ELIGIBLE_POLICIES
        WHERE
            -- Policy sale date must fall between report start and end dates
            SALES_DATE BETWEEN $REPORT_START_DATE AND $REPORT_END_DATE
            -- Ignore policies with no active months
            AND ABS(DATEDIFF(MONTH, VALID_FROM, VALID_TO)) > 0
    ),

    -- Group commissions by sale month
    COMMISSION_AGGREGATED_BY_MONTH AS (
        SELECT
            DATE_TRUNC(MONTH, SALES_DATE) AS MONTH,
            SUM(COMMISSION) AS COMMISSION,
            COUNT(*) AS AMOUNT_OF_SOLD_POLICIES
        FROM
            ALL_ELIGIBLE_POLICIES_WITH_COMMISSION
        GROUP BY
            MONTH
        ORDER BY
            MONTH
    ),

    -- Group clawbacks by cancellation month
    CLAWBACK_AGGREGATED_BY_MONTH AS (
        SELECT
            DATE_TRUNC(MONTH, CANCEL_DATE) AS MONTH,
            SUM(CLAWBACK) AS CLAWBACK,
            COUNT(*) AS AMOUNT_OF_CANCELED_POLICIES
        FROM
            ALL_ELIGIBLE_POLICIES_WITH_COMMISSION
        GROUP BY
            MONTH
        ORDER BY
            MONTH
    )

-- Create monthly report
SELECT
    TO_CHAR(COMMISSION_AGGREGATED_BY_MONTH.MONTH, 'MMMM') AS MONTH,
    CONCAT(COMMISSION, ' SEK') AS COMMISSION,
    CONCAT(COALESCE(ROUND(CLAWBACK, 2), 0), ' SEK') AS CLAWBACK,
    CONCAT(ROUND(COMMISSION - CLAWBACK, 2), ' SEK') AS NET_BALANCE,
    CONCAT(ROUND(AMOUNT_OF_CANCELED_POLICIES / AMOUNT_OF_SOLD_POLICIES * 100, 2), ' %') AS CHURN_RATE,
    AMOUNT_OF_CANCELED_POLICIES,
    AMOUNT_OF_SOLD_POLICIES

FROM
    COMMISSION_AGGREGATED_BY_MONTH
    LEFT JOIN CLAWBACK_AGGREGATED_BY_MONTH
        ON COMMISSION_AGGREGATED_BY_MONTH.MONTH = CLAWBACK_AGGREGATED_BY_MONTH.MONTH
ORDER BY
    COMMISSION_AGGREGATED_BY_MONTH.MONTH;