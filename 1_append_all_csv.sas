/*======================================================================
  Append all CSV files under D:\MyDatabase\Comovement\daily_return
  into one permanent SAS dataset.
  CSV columns: Stkcd, Trddt, Dsmvosd (float mktcap), Dretnd
  Output: COMOVE.daily_returns_2000to2025
  Read with an explicit INFILE data step (NOT proc import): CSMAR quotes
  every field, so proc import would read the numbers as CHARACTER with a
  per-file length, and proc append force would then TRUNCATE the longer
  large-cap Dsmvosd values to the first file's length. Fixed types avoid
  that and keep Dsmvosd / Dretnd numeric at full precision.
======================================================================*/
libname comove "D:\MyDatabase\Comovement\SAS";        /* permanent library */
%let csvdir = D:\MyDatabase\Comovement\daily_return;  /* directory holding the CSVs */
%let outds  = comove.daily_returns_2000to2025;        /* final output dataset */

/* 1. Get the list of all .csv file names in the directory ---------- */
filename dirlist pipe "dir /b ""&csvdir.\*.csv""";

data filelist;
    length fname $256;
    infile dirlist truncover;
    input fname $256.;
    fname = strip(fname);
    if fname ne "";
run;

/* 2. Import each file and append it ------------------------------- */
proc datasets lib=comove nolist;
    delete daily_returns_2000to2025;   /* drop old result to avoid double-appending */
quit;

%macro append_all;
    %local i n file ds;

    /* count the files */
    proc sql noprint;
        select count(*) into :n trimmed from filelist;
    quit;

    %do i = 1 %to &n;
        proc sql noprint;
            select fname into :file trimmed
            from filelist
            where monotonic() = &i;
        quit;

        %let ds = work._tmp&i;

        /* read one CSV with fixed types (DSD strips the surrounding quotes;
           Trddt kept as text, numbers read at full numeric precision)      */
        data &ds;
            infile "&csvdir.\&file" dsd firstobs=2 truncover lrecl=32767;
            length Stkcd $6 Trddt $10 Dsmvosd 8 Dretnd 8;
            input Stkcd $ Trddt $ Dsmvosd Dretnd;
        run;

        /* append (identical structure now, force just a safeguard) */
        proc append base=&outds data=&ds force;
        run;

        proc datasets lib=work nolist;
            delete _tmp&i;
        quit;
    %end;
%mend;

%append_all;
