/*======================================================================
  Compute three return comovement measures for SAME 1-digit industry
  stock pairs within each year, using the %cal_comvt macro in cal_comvt.sas
  (Anton-Polk style pairwise partial correlations).

  Output measures (one row per stkcd1-stkcd2-year):
    comvt          raw comovement (correlation of daily returns)
    comvt_mkt      comovement net of market return
    comvt_mkt_ind1 comovement net of market AND industry return
                   (industry = 1-digit CSMAR code, the leading letter)

  Input  : COMOVE.merged_2000to2025
           (Stkcd, Trddt, Year, Lagmktcap, Dretnd, IndustryCodeD, Mktret)
  Output : COMOVE.comovement_2000to2025

  ----------------------------------------------------------------------
  Pairs are restricted to the SAME 1-digit industry within a year (step 2),
  which keeps pair count and memory manageable. Full-market all-pairs blew
  up memory (SAS hit its max-obs limit, giving identical truncated counts
  across years).
  ----------------------------------------------------------------------
======================================================================*/
libname comove "/SAS/chinese_comovement/";

/* bring in the %cal_comvt macro definition */
%include "/SAS/chinese_comovement/cal_comvt.sas";

/*--- 1. Build the daily stock file expected by the macro ----------*/
/* macro needs: permno, date, ret, <industry id>, mktcap_lag           */
data m_dsf_input;
    set comove.merged_2000to2025;
    length permno $6 ind1 $1;
    permno     = Stkcd;                       /* stock id            */
    date       = Trddt;                       /* SAS date            */
    ret        = Dretnd;                      /* daily return        */
    mktcap_lag = Lagmktcap;                    /* t-1 float mkt value */
    ind1       = substr(strip(IndustryCodeD), 1, 1);  /* 1-digit industry */
    keep permno date ret ind1 mktcap_lag;
run;

/*--- 2. Build the stock-pair-year list (SAME 1-digit industry only) */
/* usable stock-years: non-missing return, weight and industry        */
proc sql;
    create table stockyear as
    select distinct permno, year(date) as year, ind1
    from m_dsf_input
    where missing(ret) = 0 and missing(mktcap_lag) = 0 and missing(ind1) = 0;
quit;

/* only pair stocks within the same year AND same 1-digit industry,
   which keeps the pair count (and memory) far below the full market. */
proc sql;
    create table stkpairyear as
    select a.permno as permno1,
           b.permno as permno2,
           a.year   as year
    from stockyear as a, stockyear as b
    where a.year = b.year
      and a.ind1 = b.ind1          /* same 1-digit industry */
      and a.permno < b.permno;     /* unordered pair, no self-pair */
quit;

/*--- 3. Run the macro --------------------------------------------*/
%cal_comvt(
    inputdata_StkPairYear = stkpairyear,
    inputdata_dsf         = m_dsf_input,
    parm_minobs           = 60,                       /* >=60 daily obs */
    outputdata_pcorrret   = comove.comovement_2000to2025,
    var_IndID             = ind1
);



%include "/SAS/func/useful.sas";

%sum(data=comove.comovement_2000to2025,
     vars=comvt comvt_mkt comvt_mkt_ind1,
     stats=n mean std min max,
     dec=3);

proc freq data=comove.comovement_2000to2025;
    tables year;
run;
