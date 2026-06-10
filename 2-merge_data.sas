/*======================================================================
  Merge daily stock returns with firm info.

  Base   : COMOVE.daily_returns_2000to2025   (Stkcd, Trddt, Dsmvosd, Dretnd)
  Firm   : firm_info_2000to2025.csv          (Symbol, ShortName, EndDate, IndustryCodeD)
           -> matched many-to-one on stock code + year (INNER JOIN)
  Output : COMOVE.merged_2000to2025

  NOTE: market return is NOT merged here -- the comovement macro builds
        market / industry returns from constituent stocks, so the CSMAR
        market series is not needed. proc import reads dates as CHARACTER,
        so they are converted explicitly below; Chinese ShortName is dropped.
======================================================================*/
libname comove "D:\MyDatabase\Comovement\SAS";
%let csvdir = D:\MyDatabase\Comovement\firm_market_data;

/*--- 1. Import firm info -------------------------------------------*/
proc import datafile="&csvdir.\firm_info_2000to2025.csv"
    out=work.firm_info_raw dbms=csv replace;
    getnames=yes;
    guessingrows=max;
run;

/* zero-padded char code + fiscal year (EndDate is char "yyyy-mm-dd") */
data work.firm_info;
    set work.firm_info_raw;
    length stkcd_c $6;
    stkcd_c = put(strip(Symbol), $6.);
    fyear   = year(input(strip(EndDate), yymmdd10.));
    keep stkcd_c fyear IndustryCodeD;
run;

/*--- 2. Normalize base, then build LAGGED float market value ------*/
/* The lag is computed on the full daily data (1999 included) sorted by
   stock & date, BEFORE any join, so the first 2000 trading day picks up
   the last 1999 trading day's float mkt value. 1999 rows are kept here
   only as a lag source; they drop out at the inner joins below.        */
data work.daily0;
    set comove.daily_returns_2000to2025;
    length stkcd_c $6;
    stkcd_c = put(strip(Stkcd), $6.);
    length tdate 8;
    tdate = input(strip(Trddt), yymmdd10.);
    dyear = year(tdate);
    keep stkcd_c tdate dyear Dsmvosd Dretnd;
run;

proc sort data=work.daily0; by stkcd_c tdate; run;

data work.daily;
    set work.daily0;
    by stkcd_c;
    lag_dsmvosd = lag(Dsmvosd);              /* previous trading day's float mkt value */
    if first.stkcd_c then lag_dsmvosd = .;   /* no prior day at a stock's first obs */
    drop Dsmvosd;                            /* final data keeps the lagged value only */
run;

/*--- 3. Inner join with firm info ---------------------------------*/
proc sql;
    create table comove.merged_2000to2025 as
    select d.stkcd_c              as Stkcd  label="Stock code",
           d.tdate                as Trddt  format=yymmdd10. label="Trading date",
           d.dyear                as Year   label="Year",
           d.lag_dsmvosd          as Lagmktcap label="Lagged float market value (t-1)",
           d.Dretnd              ,
           f.IndustryCodeD
    from work.daily as d
         inner join work.firm_info as f
            on  d.stkcd_c = f.stkcd_c
            and d.dyear   = f.fyear
    order by Stkcd, Trddt;
quit;
