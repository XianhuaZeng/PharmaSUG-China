%macro AddVar(in_data=
            , in_var=
            , splitchar=~
            , maxlen=200
            , out_data=
            , out_pre=
              );

data _null_;
    call symput("ERR", "ERR"||"OR:");
run;

/*Checks*/
%if "&splitchar" = "/" or "&splitchar" = "\" %then %do;
    %put &err \ or / CAN NOT BE USED AS SPLIT CHARACTER. MACRO TERMINATING.;
    %goto exit;
%end;

/*Check if a split character in the input variable*/
%let flag=0;

data _null_;
    set &in_data;
    if "&splitchar" not in ("", "/", "\") then do;
        if prxmatch("/\&splitchar/", &in_var) then call symputx('flag', 1);
    end;
run;

%if &flag=1 %then %do;
    %put &err A SPLIT CHARACTER(&splitchar) WAS FOUND IN VARIABLE &in_var.. AddVar TERMINATING;
    %goto exit;
%end;

/*Flag dataset*/
proc sql noprint;
    select distinct max(length(&in_var)) into :lngth
        from &in_data
        ;
quit;

%if &lngth > &maxlen %then %do;
/*Insert split character*/
data &in_data;
    set &in_data;
    length _&in_var._ $32767;
    _&in_var._=prxchange("s/(.{1,&maxlen})([\s]|$)/\1&splitchar/", -1, cats(&in_var));
    drop &in_var;
run;

/*Number of variables*/
proc sql noprint;
    select cats(max(count(_&in_var._, "&splitchar"))-1) into :varn
        from &in_data
        ;
quit;

data &out_data;
    set &in_data;
    array vlst{*} $200 &out_pre. &out_pre.1 - &out_pre.&varn;
    do i=1 to %eval(&varn+1);
        vlst(i)=scan(_&in_var._, i, "&splitchar");
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

/*if exit conditions exist, program will jump to this point*/
%exit:

%mend AddVar;
