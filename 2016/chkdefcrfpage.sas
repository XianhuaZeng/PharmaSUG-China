/*-------------------------------------------------------------------------------------
Author:          Xianhua Zeng
Creation Date:   22May2016
Program Purpose: To do the CRF page number consistency check between define.xml and blank aCRF
-------------------------------------------------------------------------------------*/
%macro ChkDefCrfPage(defcrfpath =
            	      , xmlmappath =
            	      , outpath    =
                     );

/*Prevent multi-threaded sorting and message to the SAS log about the maximum length for strings in quotation marks*/
options NOTHREADS NOQUOTELENMAX;

/*Read define.xml into SAS dataset*/
filename define "&defcrfpath/define.xml";
filename defmap "&xmlmappath/def2sas.map";
libname  define xmlv2 xmlmap=defmap automap=replace access=readonly;

proc copy in=define out=work;
run;

/*Variable metadata*/
proc sql;
    create table vardef as
        select ITEMOID, ORIGIN
        from define.itemref1 a
        left join
        define.itemdef b
        on a.ITEMOID=b.OID
        ;
quit;

/*Derive the CRF page*/
data define;
    set vardef;
    length DOMAIN $2 VARNAME $8 PAGE_DEF $500;
    if not prxmatch("/^SUPP/", cats(ITEMOID)) and prxmatch("/CRF/o", ORIGIN);
    DOMAIN=scan(ITEMOID, 1, ".");
    VARNAME=scan(ITEMOID, 2, ".");
    PAGE_DEF=cats(prxchange("s/[a-z]+,*|,\s*[a-z]+//io", -1, cats(ORIGIN)));
    PAGE_DEF=cats(prxchange("s/,\s*/, /io", -1, cats(PAGE_DEF)));
    keep DOMAIN VARNAME PAGE_DEF;
    proc sort nodupkey;
    by DOMAIN VARNAME PAGE_DEF;
run;

/*Read comments of blankcrf.pdf into SAS dataset*/
filename blankcrf "&defcrfpath/blankcrf.xfdf";
filename acrfmap "&xmlmappath/acrf2sas.map";
libname  blankcrf xmlv2 xmlmap=acrfmap automap=replace access=readonly;

proc copy in=blankcrf out=work;
run;

/*Combine the annotations and delete unwanted record*/
data comments01;
    merge p span;
    by P_ORDINAL;
    length COMMENTS COMMENTSL $32767;
    COMMENTS=catx(" ", P, SPAN);
    COMMENTS=compress(COMMENTS, , "kw");
    COMMENTSL=lag(COMMENTS);
    if countc(COMMENTS, "=")=1 then COMMENTS=scan(COMMENTS, 1, "=");
    if prxmatch("/^(note|note:|example|example:|:|\d+\.)$/io", cats(COMMENTSL)) then COMMENTS="Note: "||cats(COMMENTS);
    if not prxmatch("/^(note|example)/io", cats(COMMENTS));
    FREETEXT_ORDINAL=BODY_ORDINAL;
run;

/*Derive CRF page*/
data comments02;
    merge comments01 freetext;
    by FREETEXT_ORDINAL;
    PAGE=PAGE+1;
    keep COMMENTS PAGE;
run;

/*Variables list*/
proc sql noprint;
    select distinct VARNAME into :varlist separated by "|"
        from define
        ;
quit;

/* Extract variable name from &varlist*/
data comments03;
    set comments02;
    retain REX;
    if _N_=1 then REX=prxparse("s/.*?(\b(?:&varlist)\b)?/\1 /");
    COMMENTS=cats(compbl(prxchange(REX, -1, cats(COMMENTS))));
    if not missing(COMMENTS);
run;

/*Split COMMENTS having multiple delimiters " "*/
data comments03;
    set comments03;
    length VARNAME $8;
    I=1;
    if prxmatch("/\s/", cats(COMMENTS)) then do until(scan(COMMENTS, I, " ")="");
        VARNAME=cats(scan(COMMENTS, I, " "));
        output;
        I+1;
    end;
    else do;
        VARNAME=COMMENTS;
        output;
    end;
run;

/*Derive DOMAIN*/
data comments03;
    length DOMAIN $2 VARNAME $8;
    set comments03;
    if prxmatch("/SUBJID|DTHDTC|BRTHDTC|AGE|AGEU|SEX|RACE|ETHNIC/o", VARNAME) then DOMAIN="DM";
    else DOMAIN=substr(VARNAME, 1, 2);
    keep DOMAIN VARNAME PAGE;
    proc sort nodupkey;
    by DOMAIN VARNAME PAGE;
run;

/*Combine the crf page*/
data acrf;
    set comments03;
    by DOMAIN VARNAME;
    length PAGE_CRF $500;
    retain PAGE_CRF ;
    if first.VARNAME then PAGE_CRF=cats(PAGE);
    else PAGE_CRF=catx(", ", PAGE_CRF, cats(PAGE));
    if last.VARNAME;
    drop PAGE;
run;

/*Check*/
data ChkDefCrfPage;
    merge define acrf;
    by DOMAIN VARNAME;
    if PAGE_DEF^=PAGE_CRF;
    label DOMAIN   = "Domain Abbreviation"
          VARNAME  = "SDTM Variable"
          PAGE_DEF = "CRF Page in Define.xml"
          PAGE_CRF = "CRF Page in Annotated CRF"
          ;
run;

/*Produce validation report*/
ods path work(update) sashelp.tmplmst(read);

ods listing close;
ods tagsets.excelxp file="&outpath/ChkDefCrfPage_%sysfunc(date(),yymmddn8.).xls"
                    options(embedded_titles       = "yes"
                            autofilter            = "all"
                            orientation           = "landscape"
                            sheet_name            = "ChkDefCrfPage"
                            autofit_height        = "yes"
                            print_footer          =  " "
                            row_repeat            = "1-3"
                            frozen_headers        = "3"
                            absolute_column_width = "15, 10, 50, 50"
                            );

title1 j=l "CRF page number consistency check (define.xml vs annotated CRF)";
title2;

proc print data=ChkDefCrfPage width=min label noobs;
run;

ods tagsets.excelxp close;
ods listing;

%mend ChkDefCrfPage;