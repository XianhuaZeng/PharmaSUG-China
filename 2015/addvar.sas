/*-------------------------------------------------------------------------------------
Author:          Xianhua Zeng
Creation Date:   02Nov2014
Program Purpose: To add variables to SDTM standard domains
-------------------------------------------------------------------------------------*/

/*Start programming*/
%macro addvar(in_data=, in_var=, split=, maxlen=, out_data=, out_pre=);

data _null_;
    call symput("ERR", "ERR"||"OR:");
run;

/*Required parameters are present*/
%if %nrbquote(&in_data) = %then %do;
    %put &err INPUT DATASET(in_data) CAN NOT BE MISSING. AddVar TERMINATING;
    %goto exit;
%end;
%if %nrbquote(&in_var) = %then %do;
    %put &err INPUT VARIABLE(in_var) CAN NOT BE MISSING. AddVar TERMINATING;
    %goto exit;
%end;
%if %nrbquote(&split) = %then %do;
    %put &err SPLIT CHARACTER(split)  CAN NOT BE MISSING. AddVar TERMINATING;
    %goto exit;
%end;
%if %nrbquote(&maxlen) = %then %do;
    %put &err MAXIMUM LENGTH OF SPLIT PART(maxlen) CAN NOT BE MISSING. AddVar TERMINATING;
    %goto exit;
%end;
%if %nrbquote(&out_data) = %then %do;
    %put &err OUTPUT DATASET(out_data) CAN NOT BE MISSING. AddVar TERMINATING;
    %goto exit;
%end;
%if %nrbquote(&out_pre) = %then %do;
    %put &err PREFIX LABEL FOR NEWLY CREATED VARIABLES(out_pre) CAN NOT BE MISSING. AddVar TERMINATING;
    %goto exit;
%end;
%if "&split" = "/" or "&split" = "\" %then %do;
    %put &err \ or / CAN NOT BE USED AS SPLIT CHARACTER. MACRO TERMINATING.;
    %goto exit;
%end;

/*Look for a split char in the input variable*/
%let flag=0;

data &in_data;
    set &in_data;
    if "&split" not in ("", "/", "\") then do;
        if prxmatch("/\&split/", &in_var) then call symputx('flag',1);
    end;
run;

%if &flag=1 %then %do;
    %put &err A SPLIT CHARACTER(&split) WAS FOUND IN VARIABLE &in_var.. AddVar TERMINATING;
    %goto exit;
%end;

/*Flag dataset*/
proc sql noprint;
    select distinct max(length(&in_var)) into :lngth
        from &in_data;
quit;

%if &lngth > &maxlen %then %do;
    /*Make the split*/
    data &in_data;
        set &in_data;
        length _&in_var._ $32767;
        _&in_var._=prxchange("s/(.{1,&maxlen})([\s]|$)/\1&split/", -1, cats(&in_var));
        drop &in_var;
    run;

    /*Number of variables*/
    proc sql noprint;
        select cats(max(count(_&in_var._, "&split"))-1) into :varn
            from &in_data;
    quit;

    data &out_data;
        set &in_data;
        array vlst{*} $200 &out_pre. &out_pre.1 - &out_pre.&varn;
        do i=1 to %eval(&varn+1);
    	    vlst(i)=scan(_&in_var._, i, "&split");
        end;
        drop _&in_var._ i;
    run;
%end;
%else %do;
    data &out_data; 
        set &in_data(rename=&in_var=_&in_var._); 
        length &out_pre $200; 
        &out_pre=_&in_var._; 
        drop _&in_var._; 
    run;
%end;

/*if exit conditions exist, program will skip to this point*/
%exit:

%mend addvar;

/*Using example*/
/*Test data*/
data test;
    infile cards truncover;
    input COVAL $600. ;
cards;
COMPARED TO PREVIOUS ECG, SIGNIFICANT CHANGES HAVE OCCURRED DUE TO CRITERIA FOR POSSIBLE ANTERIOR INFARCT GONE
COMPARED TO BASELINE ECG, SIGNIFICANT CHANGES HAVE OCCURRED DUE TO NON-SPECIFIC INTRA-VENTRICULAR CONDUCTION DELAY IS SEEN  COMPARED TO PREVIOUS ECG, SIGNIFICANT CHANGES HAVE OCCURRED DUE TO NON-SPECIFIC INTRA-VENTRICULAR CONDUCTION DELAY IS SEEN
POSSIBLE WOLFF-PARKINSON-WHITE COMPARED TO BASELINE ECG, SIGNIFICANT CHANGES HAVE CCURRED DUE TO POSSIBLE WOLFF-PARKINSON-WHITE IS SEEN  COMPARED TO PREVIOUS ECG, SIGNIFICANT CHANGES HAVE OCCURREDD DUE TO POSSIBLE WOLFF-PARKINSON-WHITE IS SEEN
COMPARED TO BASELINE ECG, SIGNIFICANT CHANGES HAVE OCCURRED DUE TO AGE UNDETERMINED, SEPTAL MI IS SEEN  COMPARED TO PREVIOUS ECG, SIGNIFICANT CHANGES HAVE OCCURRED DUE TO AGE UNDETERMINED, SEPTAL MI IS SEEN
PROLONGED QT FULLY PACED BEAT, THE QT CHANGE AND QT PROLONGATION SHOULD BE ONSIDERED UNDER THESE CIRCUMSTANCES AND UNLIKELY TO BE DRUG EFFECT COMPARED TO BASELINE ECG, SIGNIFICANT CHANGES HAVE OCCURRED DUE TO QTCB CHANGED BY >60 MSEC FROM BASELINE COMPARED TO BASELINE ECG, SIGNIFICANT CHANGES HAVE OCCURRED DUE TO AV SEQUENTIAL OR DUAL CHAMBER ELECTRONIC PACEMAKER IS SEEN COMPARED TO PREVIOUS ECG, SIGNIFICANT CHANG HAVE OCCURRED DUE TO AV SEQUENTIAL OR DUAL CHAMBER ELECTRONIC PACEMAKER IS SEEN
;
run;

/*Invoke macro*/
%AddVar(  in_data=test
        , in_var=coval
        , split=~
        , maxlen=200
        , out_data=want
        , out_pre=coval
        )
