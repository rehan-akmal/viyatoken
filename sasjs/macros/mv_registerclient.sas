/**
  @file mv_registerclient.sas
  @brief Register Client and Secret (admin task)
  @details When building apps on SAS Viya, an client id and secret is required.
  This macro will obtain the Consul Token and use that to call the Web Service.

    more info: https://developer.sas.com/reference/auth/#register
    and: http://proc-x.com/2019/01/authentication-to-sas-viya-a-couple-of-approaches/

  The default viyaroot location is /opt/sas/viya/config

  M3 required due to proc http headers

  Usage:

      %* compile macros;
      filename mc url "https://raw.githubusercontent.com/macropeople/macrocore/master/mc_all.sas";
      %inc mc;

      %* specific client with just openid scope;
      %mv_registerclient(client_id=YourClient
        ,client_secret=YourSecret
        ,scopes=openid
      )

      %* generate random client details with all scopes;
      %mv_registerclient(scopes=openid *)

      %* generate random client with 90/180 second access/refresh token expiry;
      %mv_registerclient(scopes=openid *
        ,access_token_validity=90
        ,refresh_token_validity=180
      )

  @param client_id= The client name.  Auto generated if blank.
  @param client_secret= Client secret  Auto generated if client is blank.
  @param scopes= list of space-seperated unquoted scopes (default is openid)
  @param grant_type= valid values are "password" or "authorization_code" (unquoted)
  @param outds= the dataset to contain the registered client id and secret
  @param access_token_validity= The duration of validity of the access token 
    in seconds.  A value of DEFAULT will omit the entry (and use system default)
  @param refresh_token_validity= The duration of validity of the refresh token
    in seconds.  A value of DEFAULT will omit the entry (and use system default)
  @param name= A human readable name for the client
  @param required_user_groups= A list of group names. If a user does not belong 
    to all the required groups, the user will not be authenticated and no tokens 
    are issued to this client for that user. If this field is not specified, 
    authentication and token issuance proceeds normally.
  @param autoapprove= During the auth step the user can choose which scope to 
    apply.  Setting this to true will autoapprove all the client scopes.
  @param use_session= If true, access tokens issued to this client will be 
    associated with an HTTP session and revoked upon logout or time-out.
    
  @version VIYA V.03.04
  @author Allan Bowe
  @source https://github.com/macropeople/macrocore

  <h4> Dependencies </h4>
  @li mp_abort.sas
  @li mf_getplatform.sas
  @li mf_getuniquefileref.sas
  @li mf_getuniquelibref.sas
  @li mf_loc.sas
  @li mf_getquotedstr.sas

**/

%macro mv_registerclient(client_id=
    ,client_secret=
    ,client_name=
    ,scopes=
    ,grant_type=authorization_code
    ,required_user_groups=
    ,autoapprove=
    ,use_session=
    ,outds=mv_registerclient
    ,access_token_validity=DEFAULT
    ,refresh_token_validity=DEFAULT
  );
%local consul_token fname1 fname2 fname3 libref access_token url;


options noquotelenmax;
/* first, get consul token needed to get client id / secret */
data _null_;
  infile "%mf_loc(VIYACONFIG)/etc/SASSecurityCertificateFramework/tokens/consul/default/client.token";
  input token:$64.;
  call symputx('consul_token',token);
run;

%local base_uri; /* location of rest apis */
%let base_uri=%mf_getplatform(VIYARESTAPI);

/* request the client details */
%let fname1=%mf_getuniquefileref();
proc http method='POST' out=&fname1
    url="&base_uri/SASLogon/oauth/clients/consul?callback=false%str(&)serviceId=app";
    headers "X-Consul-Token"="&consul_token";
run;

%let libref=%mf_getuniquelibref();
libname &libref JSON fileref=&fname1;

/* extract the token */
data _null_;
  set &libref..root;
  call symputx('access_token',access_token,'l');
run;

/**
 * register the new client
 */
%let fname2=%mf_getuniquefileref();
%if x&client_id.x=xx %then %do;
  %let client_id=client_%sysfunc(ranuni(0),hex16.);
  %let client_secret=secret_%sysfunc(ranuni(0),hex16.);
%end;

%let scopes=%sysfunc(coalescec(&scopes,openid));
%let scopes=%mf_getquotedstr(&scopes,QUOTE=D);
%let authorized_grant_types=%mf_getquotedstr(&authorized_grant_types,QUOTE=D);
%let required_user_groups=%mf_getquotedstr(&required_user_groups,QUOTE=D);

data _null_;
  file &fname2;
  length clientid clientsecret clientname scope grant_types reqd_groups
    autoapprove $256.;
  clientid='"client_id":'!!quote(trim(symget('client_id')));
  clientsecret=',"client_secret":'!!quote(trim(symget('client_secret')));
  clientname=',"name":'!!quote(trim(symget('client_name')));
  scope=',"scope":['!!symget('scopes')!!'],';
  grant_types=',"authorized_grant_types": ['!!symget('grant_type')!!']';
  reqd_groups=',"required_user_groups":['!!symget('required_user_groups')!!']';
  autoapprove=trim(symget('autoapprove'));
  if not missing(autoapprove) then autoapprove=',"autoapprove":['!!autoapprove!!']';
  use_session=trim(symget('use_session'));
  if not missing(use_session) then use_session=',"use_session":['!!use_session!!']';
  
  put '{'  clientid  ;
  put clientsecret ;
  put clientname;
  put scope;
  put grant_types;
  put reqd_groups;
  put autoapprove;
  put use_session;
%if &access_token_validity ne DEFAULT %then %do;
  put ',"access_token_validity":' "&access_token_validity";
%end;
%if &refresh_token_validity ne DEFAULT %then %do;
  put  ',"refresh_token_validity":' "&refresh_token_validity";
%end;

  put '"redirect_uri": "urn:ietf:wg:oauth:2.0:oob"}';
run;

%let fname3=%mf_getuniquefileref();
proc http method='POST' in=&fname2 out=&fname3
    url="&base_uri/SASLogon/oauth/clients";
    headers "Content-Type"="application/json"
            "Authorization"="Bearer &access_token";
run;

/* show response */
%let err=NONE;
data _null_;
  infile &fname3;
  input;
  if _infile_=:'{"err'!!'or":' then do;
    length message $32767;
    message=scan(_infile_,-2,'"');
    call symputx('err',message,'l');
  end;
run;
%if &err ne NONE %then %do;
  %put %str(ERR)OR: &err;
  %return;
%end;

/* prepare url */
%if &grant_type=authorization_code %then %do;
  data _null_;
    if symexist('_baseurl') then do;
      url=symget('_baseurl');
      if subpad(url,length(url)-9,9)='SASStudio'
        then url=substr(url,1,length(url)-11);
      else url="&systcpiphostname";
    end;
    else url="&systcpiphostname";
    call symputx('url',url);
  run;
%end;

%put Please provide the following details to the developer:;
%put ;
%put CLIENT_ID=&client_id;
%put CLIENT_SECRET=&client_secret;
%put GRANT_TYPE=&grant_type;
%put;
%if &grant_type=authorization_code %then %do;
  /* cannot use base_uri here as it includes the protocol which may be incorrect externally */
  %put NOTE: The developer must also register below and select 'openid' to get the grant code:;
  %put NOTE- ;
  %put NOTE- &url/SASLogon/oauth/authorize?client_id=&client_id%str(&)response_type=code;
  %put NOTE- ;
%end;

data &outds;
  client_id=symget('client_id');
  client_secret=symget('client_secret');
run;

/* clear refs */
filename &fname1 clear;
filename &fname2 clear;
filename &fname3 clear;
libname &libref clear;

%mend;
