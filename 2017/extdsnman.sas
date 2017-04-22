/*-------------------------------------------------------------------------------------
 SAS Version:      9.2 and above
 Operating System: UNIX
---------------------------------------------------------------------------------------

 Author:           Xianhua Zeng
 Creation Date:    29Nov2016

 Program Purpose:  To create program inventory for ADRG

 Macro Parameters: p_path - parent directory's path where programs are located
                   m_path - path where macros are located
                   kword  - library name of analysis datasets or SDTM domain
                   o_path - path where program inventory is located

 Output:           Program inventory.xls
-------------------------------------------------------------------------------------*/

%macro extdsnman(p_path =, 
                  m_path =, 
                  kword  = analysis|raw, 
                  o_path = 
                  );

/*To mute "WARNING: The quoted string currently being processed has become more than 262 characters long. You may have unbalanced quotation marks."*/
options NOQUOTELENMAX;

/*List all files within a directory including subdirectories*/
filename dir pipe "find &p_path -name '*.sas'";

data code;
    infile dir truncover lrecl=1024;
    length PATH $1024 FNAME $200;
    input PATH 1-1024;
    retain RE;
    if _N_=1 then RE=prxparse('s/(.+)\/(.+?)/\2/');
    FNAME=prxchange(RE, 1, PATH);
    /*Read all files within in a directory including subdirectories into a dataset*/
    RC_FILE=filename('code', PATH, ,'LRECL=32767');
    FID=fopen('code');
    do while (fread(FID)=0);
        length CODELINE $32767;
        RC_READ=fget(FID, CODELINE, 32767);
        CODELINE=compress(CODELINE, , 'kw');
        if ^missing(compress(CODELINE)) then output;
    end;
    CLOSE=fclose(FID);
    RC_FILE=filename('code');
    keep PATH CODELINE FNAME;
run;

/*Close the pipe*/
filename dir clear;

%macro ftype(type=);
data temp01;
    set code;
    retain RE1 RE2;
    if _N_=1 then do;
        RE1=%if &type=INPUT %then prxparse("/\b(&kword)\.(?=\w{1,32})([a-zA-Z_][a-zA-Z0-9_]*)/"); 
            %else prxparse('/%(?=\w{1,32})[a-zA-Z_][a-zA-Z0-9_]*\(?/');;
        RE2=prxparse('/^(\*|%\*|\/\*).+$/');
    end;
    if prxmatch(RE1, CODELINE) and ^ prxmatch(RE2, cats(CODELINE));
    proc sort nodupkey;
    by PATH FNAME CODELINE;
run;

data temp02;
    set temp01;
    length &type $32767;
    retain RE;
    if _N_=1 then RE=%if &type=INPUT %then prxparse("s/.*?(?:(?:&kword)\.(\w+))?/\1 /i");
                     %else prxparse("s/.*?(?:%(&mlist)\b)?/\1 /i");;
    &type=compbl(prxchange(RE, -1, CODELINE));
    &type=prxchange('s/ /, /o', -1, cats(&type));
run;

data &type.S;
    set temp02;
    by PATH FNAME;
    length &type.S $32767;
    retain &type.S;
    if first.FNAME then &type.S=cats(&type);
    else &type.S=catx(", ", &type.S, &type);
    if last.FNAME;
    retain RE1 RE2;
    if _N_=1 then do;
        RE1=prxparse('s/(\b.+?\b)(,\s.*?)(\b\1+\b)/\2\3/i');
        RE2=prxparse('/(\b.+?\b)(,\s.*?)(\b\1+\b)/i');
    end;
    /*Remove repeated values*/
    do i=1 to 100;
        &type.S=prxchange(RE1, -1, cats(&type.S));
        if not prxmatch(RE2, cats(&type.S)) then leave;
    end;
    %if &type=INPUT %then &type.S=prxchange('s/'||cats(scan(FNAME, 1, '.'))||'//i', -1, cats(&type.S));;
    &type.S=prxchange('s/(, )+/, /o', -1, cats(&type.S));
    &type.S=prxchange('s/^(, )+|(,\s?)+$//o', -1, cats(&type.S));
    %if &type=MACRO %then %do;
        if ^missing(&type.S) then do;
            &type.S=prxchange('s/,|$/.sas, /o', -1, cats(&type.S));
            &type.S=prxchange('s/,$//o', -1, cats(&type.S));
        end;
    %end;
    keep FNAME &type.S;
run;
%mend ftype;

/*Dataset name*/
%ftype(type=INPUT)

/*List all macros within macro library*/
filename macro pipe "find &m_path -name '*.sas'";

data mlib;
    infile macro truncover lrecl=1024;
    length PATH $1024 FNAME $200;
    input PATH 1-1024;
    FNAME=prxchange("s/(.+)\/(.+?).sas/\2/o", 1, PATH);
run;

/*Close the pipe*/
filename macro clear;

/*Create macros list within macro library*/
proc sql noprint;
    select FNAME into :mlist separated by '|'
        from mlib
        ;
quit;

/*Macros name*/
%ftype(type=MACRO)

/*Combine all*/
proc sql;
    create table final as
        select a.FNAME 'Program name', INPUTS 'Inputs', MACROS 'Macros used'
        from code a
        left join
        inputs b
        on a.FNAME=b.FNAME
        left join 
        macros c
        on a.FNAME=c.FNAME
        ;
quit;

/*Produce report*/
ods path work(update) sashelp.tmplmst(read);

ods listing close;
ods tagsets.excelxp file="&o_path.Program inventory.xls" style=htmlblue
                    options(frozen_headers        = '1'
                            autofilter            = 'all'
                            sheet_name            = 'Inputs and macros used'
                            absolute_column_width = '15, 50, 50'
                            );

proc print data=final label noobs;
run;

ods tagsets.excelxp close;
ods listing;

%mend extdsnman;