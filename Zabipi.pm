#!/usr/bin/perl
#
# Monitoring::Zabipi is a simple, robust and clever way to access Zabbix API within Perl
# (C) DRVTiny (Andrey Konovalov)
# EMail: drvtiny // GMail
# This software is licensed under GPL v3
#
package Monitoring::Zabipi;
use v5.10.1;
use utf8;
#binmode(STDOUT, ":utf8");
use strict;
use warnings;
use DBI;
use HTTP::Date qw(str2time);
use Exporter qw(import);
use JSON::XS qw( decode_json encode_json );
use LWP::UserAgent;
use URI::Encode;
use Monitoring::Zabipi::Common qw(fillHashInd to_json_str doItemNameExpansion);
use Data::Dumper qw(Dumper);
sub new;
sub setErr;
sub zbx;
sub zbx_api_url;
sub zbx_api_version;
sub zbx_last_err;
sub zbx_json_raw;
sub getDefaultMethodParams;
sub doItemNameExpansion;
sub http_;
sub queue_get;
sub zbx_get_dbhandle;
sub fillHashInd;

our $VERSION = '0.15.7';
our @EXPORT_OK = qw(zbx zbx_set_cookie zbx_last_err zbx_json_raw zbx_api_url zbx_api_version zbx_get_dbhandle);
our @EXPORT = @EXPORT_OK;

use constant {
        DEFAULT_ITEM_DELAY	=> 30,
        HASHED_PWD_PREFIX	=> '{HASH}',
        FAILED 	=> 0,
        DONE 	=> 1,
        YES	=> 1,
        NO	=> 0,
};

my (%Config,%ErrMsg,%UserAgent,%SavedCreds);
my $JSONRaw;

my %cnfPar2cnfKey=(
        'debug'=>{     'type'=>'boolean',       'key'=>'flDebug'                 },
        'use_proxy'=>{ 'type'=>'boolean',       'key'=>'flUseProxy'              },
        'pretty'=>{    'type'=>'boolean',       'key'=>'flPrettyJSON'            },
        'wildcards'=>{ 'type'=>'boolean',       'key'=>'flSearchWildcardsEnabled'},
        'timeout'=>{   'type'=>'integer',       'key'=>'rqTimeout'               },
        'dbDSN'=>{     'type'=>'dsnString',     'key'=>'DBI.dsn'                 },
        'dbLogin'=>{   'type'=>'notEmptyString','key'=>'DBI.login'               },
        'dbPass'=>{    'type'=>'anyString',     'key'=>'DBI.pass'                },
        'dbPassword'=>'dbPass',
);

my %rx = (
        'boolean'	=> '^(?:y(?:es)?|true|ok|1|no?|false|0)$',
        'integer'	=> '^[-+]?[0-9]+$',
        'float'		=> '^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$',
        'dsnString'	=> '^dbi:(?:[^:]*:)+(?:;[^=;]+=[^=;]+)*$',
        'notEmptyString'=> '^.+$',
        'anyString'	=> '^.*$', 
);

my %Cmd2APIMethod=(
        'auth'             => 'user.authenticate',
        'cookieAuth'	   => 'user.checkAuthentication',
        'getVersion'       => 'apiinfo.version',
        'logout'           => 'user.logout',
        'searchHostByName' => 'host.get',
        'searchUserByName' => 'user.get',
        'createItem'       => 'item.create',
        'getHostInterfaces'=> 'hostinterface.get',
        'createUser'       => 'user.create',
        'getQueue'         => 'queue.get',
);
                  
my %MethodPars = (       
        'user.login' => {
            'noauth'=>1,
        },
        'user.checkAuthentication' => {
            'noauth'=>1,
        },
        'apiinfo.version' => {
            'noauth'=>1,
        },
        'queue.get'=>{
            'webcall'=>\&queue_get,
        },
        'graphimage.get'=>{
            'webcall'=>sub { return 1 },
        },
        'item.create'=>{
            'defpars'=>{'delay'=>DEFAULT_ITEM_DELAY},
        },
);
$MethodPars{'user.authenticate'} = $MethodPars{'user.login'};

my $oCookies;

sub cnfPar2cnfKey_syn2orig {
 my $v=shift;
 ref($v)?$v:cnfPar2cnfKey_syn2orig($cnfPar2cnfKey{$v})
}
$cnfPar2cnfKey{$_}=cnfPar2cnfKey_syn2orig($cnfPar2cnfKey{$_}) for grep !ref($cnfPar2cnfKey{$_}), keys %cnfPar2cnfKey;
sub new {
 setErr('Insufficient number of arguments'), return(FAILED) unless @_;
 my ($myname, $apiUrl, $hlOtherPars) = @_;
 $apiUrl="http://${apiUrl}/zabbix/api_jsonrpc.php" unless $apiUrl=~m%^https?://%;
 @Config{'apiUrl','authToken'}=($apiUrl,undef);
 $UserAgent{'dbHandle'}=undef;
 if (defined($hlOtherPars)) {
  unless (ref($hlOtherPars) eq 'HASH') {
   setErr('Last parameter of the "new" constructor (if present, and it is) must be a hash reference');
   return FAILED;
  }
  foreach my $cnfPar ( grep defined($cnfPar2cnfKey{$_}), keys %{$hlOtherPars} ) {
   my ($v, $t, $k)=($hlOtherPars->{$cnfPar},@{$cnfPar2cnfKey{$cnfPar}}{'type','key'});
   unless ($v=~m/$rx{$t}/io) {
    setErr('Wrong parameter passed to the "new" constructor: '.$cnfPar.' must be '.$t);
    return FAILED
   }
   ${&fillHashInd(\%Config,split /\./,$k)}=$t eq 'boolean'?($v=~m/y(?:es)?|true|1|ok/i?1:0):$v;
  }
  if (defined $hlOtherPars->{'debug_methods'}) {
   my $lstMethods2Dbg=$hlOtherPars->{'debug_methods'};
   if (! ref $lstMethods2Dbg) {
    $Config{'lstDebugMethods'}={ map { lc($_)=>1 } split /[,;]/,$lstMethods2Dbg };
   } elsif ((ref $lstMethods2Dbg eq 'HASH') && %{$lstMethods2Dbg} ) {
    $Config{'lstDebugMethods'}=$lstMethods2Dbg;
   } elsif ((ref $lstMethods2Dbg eq 'ARRAY') && @{$lstMethods2Dbg}) {
    $Config{'lstDebugMethods'}={ map { lc($_)=>1 } @{$lstMethods2Dbg} };
   } else {
    setErr('List of the methods to debug may be: hashref, arrayref, string');
    return FAILED
   }
  }  
 }
 ($UserAgent{'baseUrl'} = $apiUrl) =~ s%/[^/]+$%%;
 my $ua = LWP::UserAgent->new('ssl_opts' => { 'verify_hostname' => NO });
 if ( $Config{'flUseProxy'} ) {
   say STDERR 'Lets try to use environment proxy settings' if $Config{'flDebug'};
   $ua->env_proxy
 } 
 $ua->cookie_jar({'autosave' => 1});
 $ua->show_progress($Config{'flDebug'} ? 1 : 0);

 $UserAgent{'reqObj'} = $ua; 
# Try to get API version
 my $http_post = HTTP::Request->new('POST' => $apiUrl);
 $http_post->header('content-type' => 'application/json');
 $http_post->content('{"jsonrpc":"2.0","method":"apiinfo.version","params":[],"id":0}');
 my $r = $ua->request($http_post);
 unless ( $r->is_success ) {
  setErr('Cant get API version info: Zabbix API seems to be configured incorrectly');
  return FAILED
 }
 unless ( ($r->header('Content-Type') =~ m/(.+)(?:;.+)?$/)[0] =~ m%/json$%i ) {
   setErr('Cant get API version info: Unknown content-type in response headers');
   return FAILED
 }
 $Config{'apiVersion'} = decode_json( $r->decoded_content )->{'result'};
 $Cmd2APIMethod{'auth'} = 'user.login' if [$Config{'apiVersion'} =~ m/(\d+\.\d+)/]->[0] >= 2.4;
 return DONE
}

sub setErr {
 my $err_msg=scalar(shift);
 utf8::encode($err_msg);
 die $err_msg if scalar(shift);
 print STDERR $err_msg,"\n" if $Config{'flDebug'};
 $ErrMsg{'text'}=$err_msg;
 return 1;
}

sub zbx_api_url {
 return $Config{'apiUrl'} || undef;
}

sub zbx_api_version {
 return $Config{'apiVersion'} || undef;
}

sub zbx_last_err {
 return $ErrMsg{'text'} || 0;
}

sub zbx_json_raw {
 return $JSONRaw;
}

sub getDefaultMethodParams {
 my $method=shift;
 my ($mpar,$cpar)=($MethodPars{$method}{'defpars'},$Config{'default_params'}{'common'});
 return {} unless $mpar or $cpar;
 return { ref($cpar) eq 'HASH'?%{$cpar}:(),ref($mpar) eq 'HASH'?%{$mpar}:() };
}
                       
sub http_ {
 my ($method,$relUrl,$pars)=(lc(shift),shift); 
 do { setErr 'Unknown/unsupported HTTP method requested: '.$method; return 0 } unless $method eq 'get' or $method eq 'post';
 my $ua=$UserAgent{'reqObj'};
 do { setErr 'UserAgent not initialized'; return 0 } unless ref($ua) eq 'LWP::UserAgent';
 do { setErr 'UserAgent baseUrl property not set'; return 0 } unless $UserAgent{'baseUrl'};
 my $url=join(scalar(substr($relUrl,0,1) eq '/'?'':'/'),$UserAgent{'baseUrl'},$relUrl);
 my $ans=$method eq 'get'?$ua->get($url):$ua->post($url,ref($pars) eq 'HASH'?$pars:());
 do { print STDERR 'Error in HTTP response: '.$ans->status_line; return 0 } unless $ans->is_success;
 return $ans->decoded_content;
} #  <- sub http_

sub web_logout {
 http_ 'GET','/index.php?reconnect=1&sid='.$UserAgent{'SessionID'} if $UserAgent{'SessionID'};
 return 0
} # <- sub web_logout

sub queue_get {
 my $pars=shift;

 return [] unless my $html=http_('GET','queue.php?sid='.$UserAgent{'SessionID'}.'&form_refresh=1&config=2');
# print "QUEUE GET RESULT:\n{$html}\n" if $Config{'flDebug'};
 my @queue;
 if (substr($Config{'apiVersion'},0,1) eq '3') {
  $html=~s%^.*<tbody>(<tr.*?)</tbody></table>.*$%$1%s;
  @queue=split /<tr.*?>/,$html;
 } else {
  $html=~s%^.*<td>Name</td></tr>(<tr class="even_row".*?)</table>.*$%$1%s;
  @queue=split /<tr class="(?:even|odd)_row".*?>/,$html;
 }
 shift @queue;
# @QUEUE_ROW=('time_expected','time_delay','host','item_name');
 my ($selectHosts,$selectItems);
 if (ref($pars) eq 'HASH') {
  ($selectHosts,$selectItems)=@{$pars}{'selectHosts','selectItems'};
  if ($selectHosts) {
   $selectHosts=['hostid','host'] unless (ref($selectHosts) eq 'ARRAY') and scalar(@$selectHosts);
  }
  if ($selectItems) {
   $selectItems=['itemid','name'] unless (ref($selectItems) eq 'ARRAY') and scalar(@$selectItems);
   $selectHosts=['hostid'] unless $selectHosts;
  }
 }
 my (%N2H,%N2HI);
 return [ map {
  my @qitem=/<td>(.+?)<\/td>/g; 
  print "=== ${qitem[1]} ===\n";
  my @delay=$qitem[1]=~m/([0-9]+)/g;
  my ($hostName,$itemName)=@qitem[2,3];
  {
    'time_expect'=>str2time($qitem[0]),
    'time_delay'=>$delay[0]*3600*24+$delay[1]*3600+$delay[2]*60,
    'hosts'=>$selectHosts?($N2H{$hostName}||=zbx('host.get',{'search'=>{'host'=>$hostName},'searchWildcardsEnabled'=>0,'output'=>$selectHosts})):[{'host'=>$hostName}],
    'items'=>$selectItems?($N2HI{$hostName}{$itemName}||=zbx('item.get',{'hostids'=>$N2H{$hostName}[0]{'hostid'},'search'=>{'name'=>$itemName},'searchWildcardsEnabled'=>0,'output'=>$selectItems})):[{'name'=>$itemName}],
  }
 } @queue ]
} # <- sub queue_get

sub zbx_get_dbhandle {
 $UserAgent{'dbHandle'}=ref($UserAgent{'dbHandle'}) eq 'DBI::db'
  ?$UserAgent{'dbHandle'}
  :sub { 
      unless ( ref($Config{'DBI'}) eq 'HASH' and scalar(grep {defined($_)} @{$Config{'DBI'}}{'dsn','login','pass'}) == 3 ) {
       setErr 'Insufficient database connection properties given, but method or its parameter requires direct database connection';
       return undef
      }
      return DBI->connect(@{$Config{'DBI'}}{'dsn','login','pass'},{'RaiseError' => 1}) || die 'DB open error: '.$DBI::errstr
   }->()
}

my %APIPatcher=(
 'usergroup.get'=>{
   'before'=>sub {
     my ($rq,$flags)=@_;
     return 1 unless $rq->{'params'}{'selectRights'};
     return 0 unless zbx_get_dbhandle;
     delete $rq->{'params'}{'selectRights'};
     $flags->{'flSelectRights'}=1;
     return 1
   },
   'after'=>sub {
     my ($ans,$flags)=@_;
     return 1 unless $flags->{'flSelectRights'} and @$ans;
     my $dbh = zbx_get_dbhandle;
     my $sth = $dbh->prepare(
      'select usrgrp.usrgrpid,groups.groupid id,rights.permission from 
        usrgrp
         inner join rights on usrgrp.usrgrpid=rights.groupid
          inner join groups on groups.groupid=rights.id
       where usrgrp.usrgrpid in ('.join(',',map {$_->{'usrgrpid'}} @$ans).')'
                            );
     $sth->execute;
     my %rights;
     while (my $hr=$sth->fetchrow_hashref) {
      my $ugid=delete $hr->{'usrgrpid'};
      push @{$rights{$ugid}},$hr;
     }
     $_->{'rights'}=$rights{$_->{'usrgrpid'}} || [] foreach @$ans;
     1;
   },
 },
 'item.get'=>{
   'before'=>sub {
     my ($rq,$flags)=@_;
     return 1 unless $rq->{'params'}{'expandNames'};
     delete $rq->{'params'}{'expandNames'};
     $flags->{'ExpandNames'}=[];
     my $out=$rq->{'params'}{'output'};
     unless ($out eq 'extend') {
      if (ref($out) eq 'ARRAY') {
       my @UnsetInRes=
        grep { my $ma=$_;             
               ! grep /^${ma}$/,@$out;
             } 'name','key_';
       if ( @UnsetInRes ) {
        $flags->{'ExpandNames'}=\@UnsetInRes;
        push @$out,@UnsetInRes
       }
      } else {
       $rq->{'params'}{'output'}='extend';
      }
     }
     1;
   },
  'after'=>sub {
     my ($ans,$flags)=@_;
     return 1 unless $flags->{'ExpandNames'};
     doItemNameExpansion($ans,@{$flags->{'ExpandNames'}});
  },
 },
 'user.get'=>{
   'before'=>sub {
     my ($rq,$flags)=@_;
     return 1 unless $rq->{'params'}{'selectPasswd'};
     return 0 unless zbx_get_dbhandle;
     delete $rq->{'params'}{'selectPasswd'};
     $flags->{'flSelectPasswd'}=1;
   },
   'after'=>sub {
     my ($ans,$flags)=@_;
     return 1 unless $flags->{'flSelectPasswd'} or !@$ans;
     return 0 unless my $dbh = zbx_get_dbhandle;
     my %ObjByID=map {$_->{'userid'}=>$_} @$ans;
     my $sth = $dbh->prepare('select userid,passwd from users where userid in ('.join(',',keys %ObjByID).')');
     $sth->execute;
     while (my $hr=$sth->fetchrow_hashref) {
      $ObjByID{$hr->{'userid'}}{'passwd'}=HASHED_PWD_PREFIX.$hr->{'passwd'};
     }
     1;
   },   
 },
 'user.create'=>{
   'before'=>sub {
     my ($rq,$flags)=@_;
     my ($i,%HashPUsr)=(0,());
     foreach my $usr ( @{ref($rq->{'params'}) eq 'ARRAY'?$rq->{'params'}:[$rq->{'params'}]} ) {
      do {
       setErr('Cant create user without password specified in the "passwd" attribute');
       return 0
      } unless my $pass=$usr->{'passwd'};
      next unless substr($pass,0,length(HASHED_PWD_PREFIX)) eq HASHED_PWD_PREFIX;
      $usr->{'passwd'}=substr($HashPUsr{$i}=substr($pass,length(HASHED_PWD_PREFIX)),0,10);      
     } continue {
      $i++
     }
     if (%HashPUsr and !zbx_get_dbhandle) {
      setErr('It seems, you need to set hashed passwords. Sorry, but you cant directly update passwords in database without db connection!');
      return 0
     }
     $flags->{'DirSetPass'}=\%HashPUsr;
   },
   'after'=>sub {
     my ($ans,$flags)=@_;
     return 1 unless 
      ( ref($flags->{'DirSetPass'}) eq 'HASH' and my %DirSetPass=%{$flags->{'DirSetPass'}} )
       and
      ( ref($ans->{'userids'}) eq 'ARRAY' and @{$ans->{'userids'}} );
     my $dbh=zbx_get_dbhandle || die 'No database connection available';
     my $sth=$dbh->prepare('UPDATE users SET passwd=? WHERE userid=?');
     while (my ($ix,$hpass)=each %DirSetPass) {
      $sth->execute($hpass, $ans->{'userids'}[$ix]) or die 'Cant update user{userid='.$ans->{'userids'}[$ix].'} password. Database error: '.$dbh->errstr;
     }
   },   
 },  
);

sub zbx_set_cookie {
 do {
  setErr 'You must provide cookie file path to zbx_set_cookie() function';
  return
 } unless defined(my $cookieFile=shift);
 if ( -e $cookieFile and !( -f $cookieFile and -r $cookieFile ) ) {
  setErr 'Unreadable cookie file';
  return
 }   
 unless ($oCookies=HTTP::Cookies->new('file'=>$cookieFile,'autosave'=>1)) {
  setErr 'Cant create HTTP::Cookies object based on your cookie file. Check that it contains valid cookie data';
  return
 }
 $_->cookie_jar($oCookies) if $_=$UserAgent{'reqObj'};
}

# zbx internally doing some nasty things such as:
# POST $url {"jsonrpc": "2.0","method":"user.authenticate","params":{"user":"Admin","password":"zabbix"},"auth": null,"id":0}
sub zbx {
 my $what2do=shift;
 my ($req,$rslt,%flags);
 unless ( $Config{'apiVersion'} ) {
  print STDERR 'API not initialized yet, use "new" method with the correct parameters and check its return code',"\n" unless $what2do eq 'logout';
  return
 }
 my $ua=$UserAgent{'reqObj'};
 unless ($Config{'apiUrl'} and ref($ua) eq 'LWP::UserAgent') {
  print STDERR "You must use 'new' constructor first and define some mandatory configuration parameters, such as URL pointing to server-side ZabbixAPI handler\n";
  return
 }
 do {
  setErr "Unknown operation requested: $what2do";
  return
 } unless my $method=$what2do=~m/^[a-z]+?\.[a-zA-Z]+$/?$what2do:$Cmd2APIMethod{$what2do};
 
 my $mp=$MethodPars{$method};
 
 unless ($Config{'authToken'} or $mp->{'noauth'}) {
  setErr "You must be authorized first. Use 'auth' before try to '$what2do'";
  return
 } 
 
 if ( $mp->{'webcall'} ) {
  my $uriEnc=URI::Encode->new({'encode_reserved'=>1});
  unless ($Config{'flWebLoginSuccess'}) {
   return unless my $html=http_('GET','/?request=&name='.$SavedCreds{'login'}.'&password='.$uriEnc->encode($SavedCreds{'passwd'}).'&autologin=1&enter=Sign+in');
   do { setErr 'Cant get Zabbix Web Session ID'; return }
    unless ($UserAgent{'SessionID'})=$html=~m/name="sid" value="([0-9a-f]+)"/;   
   $Config{'flWebLoginSuccess'}=1;
  }
  return $mp->{'webcall'}(@_)
 }
 
# Set default params ->
 @{$req}{'jsonrpc','params','method','id'}=('2.0',getDefaultMethodParams($method),$method,0);
 my $zbxSessId;
# <- Set default params
 given ($what2do) {
  when (/^[a-z]+?\.[a-zA-Z]+$/) {
   my $userParams=shift;
   unless ( ref($userParams)=~m/^(?:ARRAY|HASH)?$/) {
    setErr 'You can specify only one of HASH-reference, ARRAY-reference of SCALAR as a second parameter for zbx()';
    return undef
   }
   $req->{'params'}=$userParams
  };
  when ('cookieAuth') {
   if ( @_ ) {
    return unless zbx_set_cookie( shift );
   } elsif (!(ref($oCookies) eq 'HTTP::Cookies')) {   
    setErr 'No cookies. You must provide cookie file path or use zbx_set_cookie() before trying to access cookieAuth method';
    return
   }
   $oCookies->scan(sub {
    $zbxSessId=$_[2] if $_[1] eq 'zbx_sessionid' and defined($_[2]) and length($_[2]);
   });
   unless ($zbxSessId) {
    setErr 'Cant find zbx_sessionid in your cookies';
    return
   }
   $req->{'params'}={'sessionid'=>$zbxSessId};
   $req->{'id'}=0;
  };
  when ('auth') {
   if (!(@_ >= 2 and @_ <= 3)) {
    setErr 'You must specify (only) login, password and (optionally) path to cookie-file for auth';
    return
   }
   @SavedCreds{'login','passwd'}=(shift,shift);
   if (@_ and ! ref $_[0]) {
    my $cookieFile=shift;
    return unless ref $oCookies eq 'HTTP::Cookies' or zbx_set_cookie($cookieFile);
   }
   $req->{'params'}={'user'=>$SavedCreds{'login'},'password'=>$SavedCreds{'passwd'}};
   $req->{'id'}=0;
  }; # <- auth
  when ('logout') {
   @{$req}{'auth','id','params'}=($Config{'authToken'},1,{});
  }; # <- logout
  when ('queue.get') {
   return queue_get();
  };
  when ('searchHostByName') {
   my $hostName=shift;
   $req->{'params'}{'output'}='extend';
   $req->{'params'}{'filter'}={'host'=>[$hostName]};
  }; # <- searchHostByName
  when ('searchUserByName') {
   $req->{'params'}{'filter'}={'alias'=>shift};
  }; # <- searchUserByName
  when ('getHostInterfaces') {
   my $hostID=shift;
   @{$req->{'params'}}{'output','hostids'}=('extend',$hostID);
  }; # <- getHostInterfaces
  when ('createUser') {
   my ($uid,$gid,$passwd)=(shift,shift,shift);
   if (!( $req->{'params'}{'usrgrps'}=[ zbx('searchGroup',{'status'=>0,'filter'=>{'name'=>$gid}})->[0] ] )) {
    setErr "Cant find group with name=$gid";
    return;
   }
   @{$req->{'params'}}{'passwd','alias'}=($passwd,$uid);
  }; # <- createUser
  when ('getVersion') {
   $req->{'params'}=[];
   shift while defined($_[0]) and ref $_[0] ne 'HASH';
  };
  default { setErr 'Command '.$what2do.' is unsupported (yet). Please make request to maintainer to add this feature';
            return }
 } # <- given ($what2do)
 if ( ref($APIPatcher{$what2do}{'before'}) eq 'CODE' ) {
  return unless &{$APIPatcher{$what2do}{'before'}}($req,\%flags);
 }
 @{$req}{'auth','id'}=($Config{'authToken'},1) if $Config{'authToken'} and ! $mp->{'noauth'};
 my $pars=$req->{'params'};
 if ($method=~m/\.(?:delete|update)/ and ! ((ref($pars) eq 'ARRAY' and scalar(@$pars)) or (ref($pars) eq 'HASH' and %$pars))) {
  setErr 'Cant execute "delete" or "update" without parameters';
  return;
 }
 $req->{'params'}{'searchWildcardsEnabled'}=1 if ($method=~m/\.get$/ && ref($req->{'params'}{'search'}) eq 'HASH') and $Config{'flSearchWildcardsEnabled'} and ! defined $req->{'params'}{'searchWildcardsEnabled'};
 # Redefine global config variables if it is specified as a 3-rd parameter to zbx() ->
 my %ConfigCopy=%Config;
 my $confPars=shift;
 $ConfigCopy{'flDebug'}=$ConfigCopy{'lstDebugMethods'}{$what2do} if defined($ConfigCopy{'lstDebugMethods'});
 @ConfigCopy{keys %{$confPars}}=values %{$confPars} if ref($confPars) eq 'HASH';
 # <-
 # You dont have possibility to freely redefine apiUrl on every zbx() call
 my $http_post = HTTP::Request->new('POST' => $Config{'apiUrl'});
 $http_post->header('content-type' => 'application/json');
 print STDERR "Request: Perl structure:\n",Dumper($req) if $ConfigCopy{'flRqDetailDebug'};
 my $jsonrq=encode_json($req);
 print STDERR "Request: In JSON format:\n${jsonrq}\n" if $ConfigCopy{'flDebug'};
 return [] if $ConfigCopy{'flDryRun'};
 $http_post->content($jsonrq);
 $ua->timeout($ConfigCopy{'rqTimeout'}) if defined $ConfigCopy{'rqTimeout'};
 $ua->show_progress(1) if $ConfigCopy{'flShowProgressBar'};
 my $ans=$ua->request($http_post);
 unless ( $ans->is_success ) {
  setErr 'HTTP POST request failed for some reason. Please double check, what you requested';
  return;
 }
 my $JSONAns=$ans->decoded_content;
 $JSONRaw=$JSONAns;
 return $JSONAns if $ConfigCopy{'flRetRawJSON'};
 $JSONAns = decode_json( $JSONAns );
 print STDERR join("\n",'Decoded content from POST:',to_json_str(\%ConfigCopy,$JSONAns),'')
  if $ConfigCopy{'flDebug'} and ! ($ConfigCopy{'flDbgResultAsListSize'} and (index($JSONAns,'"result":[')+1)); 
 if ($JSONAns->{'error'}) {
  setErr('Error received from server in reply to JSON request: '.$JSONAns->{'error'}{'data'},$ConfigCopy{'flDieOnError'});
  return;
 }
 $rslt=$JSONAns->{'result'};
 if ( $ConfigCopy{'flDebug'} and $ConfigCopy{'flDbgResultAsListSize'} ) {
  my $JSONAnsCopy;
  my @k=grep {$_ ne 'result'} keys %$JSONAns;
  @{$JSONAnsCopy}{@k}=@{$JSONAns}{@k};
  $JSONAnsCopy->{'result'}='List; Size='.scalar(@$rslt);
  print STDERR join("\n",'Decoded content from POST:',to_json_str(\%ConfigCopy,$JSONAnsCopy),'');
 }
 unless (ref($rslt) eq 'ARRAY'?scalar(@$rslt):defined($rslt)) {
  setErr 'Cant get result in JSON response for an unknown reason (no error was returned from Zabbix API)';
  die 'Empty result set was returned from the Zabbix API' if $ConfigCopy{'flDieIfEmpty'};
  return (ref($rslt) eq 'ARRAY' and !$ConfigCopy{'flRetFalseIfEmpty'})?[]:0;
 }
 given ($what2do) {
  when ('auth') {
   print STDERR "Got auth token=${rslt}\n" if $ConfigCopy{'flDebug'};
   $Config{'authToken'}=$rslt;
   if (ref $oCookies eq 'HTTP::Cookies') {
    print STDERR "Saving zbx_sessionid cookie\n" if $ConfigCopy{'flDebug'};
    die $! unless $oCookies->set_cookie( '1.1', 'zbx_sessionid'=>$rslt, '/', '', 80, 0 , 0, 3600*24*365);
   }
  };
  when ('cookieAuth') {
   if (ref($rslt) eq 'HASH') {
    print STDERR "Got valid auth token=$zbxSessId from cookie file\n" if $ConfigCopy{'flDebug'};
    $Config{'authToken'}=$zbxSessId
   }
  };
  when ('logout') {
   delete $Config{'authToken'};
   web_logout if $Config{'flWebLoginSuccess'};
  };
  return $rslt->[0] when m/search[a-zA-Z]+ByName/;
 }
 if ( ref($APIPatcher{$what2do}{'after'}) eq 'CODE' ) {
  return unless &{$APIPatcher{$what2do}{'after'}}($rslt,\%flags);
 }
 return $rslt;
}

1;

