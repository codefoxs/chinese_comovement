/*======================================================================
  MACRO  : %cal_comvt
  PURPOSE: Estimate pairwise return comovement between stocks within a
           year, following the Anton & Polk (2014, JF "Connected Stocks")
           partial-correlation approach. For every stock pair it returns:

             comvt          raw comovement  = corr(ret1, ret2)
             comvt_mkt      partial corr controlling for the market return
             comvt_mkt_ind1 partial corr controlling for market AND industry

           The market / industry returns are value-weighted (weight =
           lagged market cap) and are computed FROM the constituent stocks,
           then the focal pair's own returns (and, for industry, their own
           industry) are removed so the controls are not mechanically
           correlated with ret1 / ret2.

  PARAMETERS
    inputdata_StkPairYear : stock-pair-year list to estimate.
                            Variables: permno1, permno2, year.
    inputdata_dsf         : daily stock file (the market universe).
                            Variables: permno, date, ret, &var_IndID,
                            mktcap_lag (market cap at end of previous day).
    parm_minobs           : minimum daily observations required to keep a
                            pair (default 60, ~3 months).
    outputdata_pcorrret   : output dataset; one row per stock-pair-year,
                            id variables renamed to stkcd1 / stkcd2.
    var_IndID             : the industry-id variable name inside the dsf.

  NOTES
    * Estimation is done year by year to keep working datasets small.
    * proc corr writes the (partial) correlation into the _NAME_='RET1'
      row, column ret2; that value is what we extract.
======================================================================*/
%macro cal_comvt(inputdata_StkPairYear=,
                 inputdata_dsf=,
                 parm_minobs=60,
                 outputdata_pcorrret=,
                 var_IndID=);

    /*------------------------------------------------------------------
      0. Initialize the cumulative (all-year) output as an empty shell.
    ------------------------------------------------------------------*/
    data m_pcorr_allyear;
        set _null_;
    run;

    /*------------------------------------------------------------------
      1. Build the daily stock file with value-weighted market and
         industry returns.

         weight     = lagged market cap (market-cap weighting).
         mktret     = value-weighted return across ALL stocks on a date.
         indret     = value-weighted return within (date x industry).
         mktweight  = total weight on a date          (for later exclusion).
         indweight  = total weight within date x ind  (for later exclusion).
    ------------------------------------------------------------------*/
    proc sql;
        /* keep only usable obs: non-missing return and weight */
        create table temp1 as
        select permno,
               date,
               ret,
               &var_IndID,
               mktcap_lag as weight
        from   &inputdata_dsf
        where  missing(ret) = 0
           and missing(mktcap_lag) = 0;

        /* market return + total market weight, per date */
        create table temp2 as
        select *,
               sum(ret*weight)/sum(weight) as mktret,
               sum(weight)                 as mktweight
        from   temp1
        group by date;

        /* industry return + total industry weight, per date x industry */
        create table m_dsf_ind as
        select *,
               sum(ret*weight)/sum(weight) as indret,
               sum(weight)                 as indweight
        from   temp1
        group by date, &var_IndID
        order by permno, date;

        /* attach industry aggregates back onto the market-level table */
        create table m_dsf as
        select a.*,
               b.indret,
               b.indweight
        from   temp2       as a
        left join m_dsf_ind as b
          on  a.permno = b.permno
          and a.date   = b.date;
    quit;

    /* a stock with a missing industry code has no industry aggregates */
    data m_dsf;
        set m_dsf;
        if missing(&var_IndID) = 1 then do;
            indret    = .;
            indweight = .;
        end;
    run;

    /*------------------------------------------------------------------
      2. Determine the first and last year to loop over, taken from the
         stock-pair-year list. CALL SYMPUTX stores them as GLOBAL macro
         variables so the %DO loop below can read them.
    ------------------------------------------------------------------*/
    proc sort data=&inputdata_StkPairYear out=m_StkPairYear nodupkey;
        by year permno1 permno2;
    run;

    data _null_;
        set m_StkPairYear end=last;
        if _n_ = 1 then call symputx('parm_styear', year, 'G');
        if last    then call symputx('parm_endyear', year, 'G');
    run;

    /*==================================================================
      3. YEAR-BY-YEAR ESTIMATION
    ==================================================================*/
    %do year = &parm_styear %to &parm_endyear;

        /* progress indicator: which year is running (timestamped) */
        %put %sysfunc(datetime(), datetime20.) NOTE: ===== comvt progress: year &year (range &parm_styear-&parm_endyear) =====;

        /* this year's pairs and this year's daily data */
        data temp1;
            set m_StkPairYear;
            where year = &year;
        run;

        data temp2;
            set m_dsf;
            where year(date) = &year;
        run;

        /*--------------------------------------------------------------
          3a. Expand each pair into a daily panel by joining the daily
              data twice -- once for stock1, once for stock2 -- so each
              row holds both stocks' returns/weights/industry on a date.
        --------------------------------------------------------------*/
        proc sql;
            /* bring in stock1's daily series */
            create table temp3 as
            select a.permno1, a.permno2,
                   b.date, b.mktret, b.mktweight,
                   b.ret    as ret1,     b.weight    as weight1,
                   b.&var_IndID as ind1, b.indret as indret1, b.indweight as indweight1
            from   temp1 as a, temp2 as b
            where  a.permno1 = b.permno;

            /* bring in stock2's daily series, matched on the same date */
            create table m_dsf_pair as
            select a.*,
                   b.ret    as ret2,     b.weight    as weight2,
                   b.&var_IndID as ind2, b.indret as indret2, b.indweight as indweight2
            from   temp3 as a, temp2 as b
            where  a.permno2 = b.permno
               and a.date    = b.date
            order by a.permno1, a.permno2, date;
        quit;

        /*--------------------------------------------------------------
          3b. Build the control returns, EXCLUDING the focal pair so the
              controls are not mechanically correlated with ret1/ret2.

              mktret_exclstk : market return, dropping both stocks.
              For the market+industry controls there are two cases:
                sameind = 1  both stocks share an industry
                sameind = 0  the two stocks are in different industries
        --------------------------------------------------------------*/
        data m_dsf_pair;
            set m_dsf_pair;

            /* market return with the two focal stocks removed */
            mktret_exclstk = (mktret*mktweight - ret1*weight1 - ret2*weight2)
                             / (mktweight - weight1 - weight2);

            if missing(ind1) = 0 and missing(ind2) = 0 then do;
                if ind1 = ind2 then do;
                    /* same industry: one shared industry return */
                    sameind = 1;
                    /* market return excluding that whole industry */
                    mktret_exclind = (mktret*mktweight - indret1*indweight1)
                                     / (mktweight - indweight1);
                    /* industry return excluding both focal stocks */
                    indret_exclstk = (indret1*indweight1 - ret1*weight1 - ret2*weight2)
                                     / (indweight1 - weight1 - weight2);
                end;
                else do;
                    /* different industries: two separate industry returns */
                    sameind = 0;
                    /* market return excluding both industries */
                    mktret_exclind = (mktret*mktweight - indret1*indweight1 - indret2*indweight2)
                                     / (mktweight - indweight1 - indweight2);
                    /* each industry return excluding its own focal stock */
                    indret1_exclstk = (indret1*indweight1 - ret1*weight1)
                                      / (indweight1 - weight1);
                    indret2_exclstk = (indret2*indweight2 - ret2*weight2)
                                      / (indweight2 - weight2);
                end;
            end;
        run;

        /*==============================================================
          3c. comvt -- RAW comovement = corr(ret1, ret2)
        ==============================================================*/
        /* suppress proc corr's per-pair log to keep the log readable */
        filename junk dummy;
        proc printto log=junk;

        proc corr data=m_dsf_pair noprint outp=simple_corr_temp;
            by  permno1 permno2;
            var ret1 ret2;
        run;

        proc printto log=log;
        run;

        /* pairs meeting the minimum-obs requirement (the _TYPE_='N' row) */
        data temp1;
            set simple_corr_temp;
            where _type_ eq 'N' and ret2 >= &parm_minobs;
            keep permno1 permno2;
        run;

        /* the correlation itself (drop |r|=1 or 0, likely data errors) */
        data temp2;
            set simple_corr_temp;
            where _type_ eq 'CORR' and upcase(_name_) eq 'RET1'
                  and missing(ret2) = 0 and ret2 not in (-1 0 1);
            comvt = ret2;
            keep permno1 permno2 comvt;
        run;

        data m_corr_direct;
            merge temp1 (in=in1) temp2 (in=in2);
            by permno1 permno2;
            if in1 and in2;
        run;

        /*==============================================================
          3d. comvt_mkt -- partial corr controlling for the MARKET return
        ==============================================================*/
        filename junk dummy;
        proc printto log=junk;

        proc corr data=m_dsf_pair noprint outp=pcorr_temp;
            by      permno1 permno2;
            var     ret1 ret2;
            partial mktret_exclstk;
        run;

        proc printto log=log;
        run;

        data temp1;
            set pcorr_temp;
            where _type_ eq 'N' and ret2 >= &parm_minobs;
            keep permno1 permno2;
        run;

        data temp2;
            set pcorr_temp;
            where _type_ eq 'CORR' and upcase(_name_) eq 'RET1'
                  and missing(ret2) = 0 and ret2 not in (-1 0 1);
            comvt_mkt = ret2;
            keep permno1 permno2 comvt_mkt;
        run;

        data m_pcorr_CtrlMkt;
            merge temp1 (in=in1) temp2 (in=in2);
            by permno1 permno2;
            if in1 and in2;
        run;

        /*==============================================================
          3e. comvt_mkt_ind1 -- partial corr controlling for MARKET and
              INDUSTRY. Same-industry and different-industry pairs use
              different control sets, so they are estimated separately
              and stacked.
        ==============================================================*/
        /* --- case 1: the two stocks are in the SAME industry --- */
        filename junk dummy;
        proc printto log=junk;

        proc corr data=m_dsf_pair noprint outp=pcorr_temp;
            where   sameind = 1;
            by      permno1 permno2;
            var     ret1 ret2;
            partial mktret_exclind indret_exclstk;
        run;

        proc printto log=log;
        run;

        data temp1;
            set pcorr_temp;
            where _type_ eq 'N' and ret2 >= &parm_minobs;
            keep permno1 permno2;
        run;

        data temp2;
            set pcorr_temp;
            where _type_ eq 'CORR' and upcase(_name_) eq 'RET1'
                  and missing(ret2) = 0 and ret2 not in (-1 0 1);
            comvt_mkt_ind1 = ret2;
            keep permno1 permno2 comvt_mkt_ind1;
        run;

        data m_pcorr_CtrlMktInd1;
            merge temp1 (in=in1) temp2 (in=in2);
            by permno1 permno2;
            if in1 and in2;
        run;

        /* --- case 2: the two stocks are in DIFFERENT industries --- */
        filename junk dummy;
        proc printto log=junk;

        proc corr data=m_dsf_pair noprint outp=pcorr_temp;
            where   sameind = 0;
            by      permno1 permno2;
            var     ret1 ret2;
            partial mktret_exclind indret1_exclstk indret2_exclstk;
        run;

        proc printto log=log;
        run;

        data temp1;
            set pcorr_temp;
            where _type_ eq 'N' and ret2 >= &parm_minobs;
            keep permno1 permno2;
        run;

        data temp2;
            set pcorr_temp;
            where _type_ eq 'CORR' and upcase(_name_) eq 'RET1'
                  and missing(ret2) = 0 and ret2 not in (-1 0 1);
            comvt_mkt_ind1 = ret2;
            keep permno1 permno2 comvt_mkt_ind1;
        run;

        data m_pcorr_CtrlMktInd2;
            merge temp1 (in=in1) temp2 (in=in2);
            by permno1 permno2;
            if in1 and in2;
        run;

        /*==============================================================
          3f. Combine the three measures for this year, then append to
              the cumulative all-year dataset.
        ==============================================================*/
        /* stack same-industry and different-industry results */
        data m_pcorr_CtrlMktInd;
            set m_pcorr_CtrlMktInd1 m_pcorr_CtrlMktInd2;
            by permno1 permno2;
        run;

        /* merge raw + market-controlled + market&industry-controlled */
        data m_pcorr_year;
            merge m_corr_direct m_pcorr_CtrlMkt m_pcorr_CtrlMktInd;
            by permno1 permno2;
        run;

        /* append this year (tagging the year) to the running output */
        data m_pcorr_allyear;
            set m_pcorr_allyear m_pcorr_year (in=in1);
            if in1 then year = &year;
        run;

    %end;
    /*================ end of year-by-year estimation =================*/

    /*------------------------------------------------------------------
      4. Final output: rename the id variables to stkcd1 / stkcd2.
    ------------------------------------------------------------------*/
    data &outputdata_pcorrret;
        set m_pcorr_allyear;
        rename permno1 = stkcd1
               permno2 = stkcd2;
    run;

%mend cal_comvt;
