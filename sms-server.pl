#!/usr/bin/perl

use Switch;
use Time::HiRes qw(gettimeofday tv_interval);
use POSIX;
use Cwd qw(getcwd);
#use Fcntl qw(F_SETFL, O_SYNC);
use IO::Socket::INET;
use IO::Select;
use DBI;
use Getopt::Long;
use Pod::Usage;
use Config::IniFiles;
use Storable qw(store);
#use Net::SMTP_auth;
use Mail::POP3Client;
use MIME::Parser;

my %cmdline_options     = ();
my $show_help           = 0;
my $show_man            = 0;
my $run_daemon          = 0;
my $log_out             = '';
my $log_err             = '';
my $pidfile             = '';
my $listening_host      = '0.0.0.0';
my $listening_port      = 44444;
my @authentication      = ();
my $socket_debug        = 0;
my $phone_remleadzero   = 1; # TODO: add to cmdline param and cfgfile
my $phone_numlen        = 8;
my $phone_aclen         = 2;
my $phone_defaultac     = '11';
my $phone_defaultcc     = '55';
my $verbose_level       = 1;
my $use_mysql           = 0;
my $mysql_db            = 'asterisk';
my $mysql_socket        = '/tmp/mysql.sock';
my $use_csv             = 0;
my $csv_dir             = '.';
my $csv_file            = 'sms-messages.csv';
my $ssl_ca_file         = '';
my $use_xmpp            = 0;
my $xmpp_debug          = 0;
my $xmpp_domain         = '';
my $xmpp_user           = '';
my $xmpp_password       = '';
my @xmpp_remote_jid     = ();
my $use_smtp            = 0;
my $smtp_host           = 'localhost';
my $smtp_domain         = '';
my $smtp_port           = 0;
my $smtp_ssl            = 0;
my $smtp_auth_type      = 'PLAIN';
my $smtp_auth_user      = '';
my $smtp_auth_pass      = '';
my $use_pop3            = 0;
my $pop3_host           = '';
my $pop3_user           = '';
my $pop3_pass           = '';
my $pop3_file           = '';
my $pop3_interval       = 120;
my $mail_local_address  = '';
my @mail_remote_address = ();

my $running = 0;

sub config_boolean {
  my $val = shift;
  if ($val =~ /^[+-][0-9]+$/) {
    return 1 if $val != 0;
    return 0;
  }
  return 1 if $val =~ /^(?:y(?:es)?|t(?:rue)?|ok(?:ay)?|enable)$/i;
  return 0;
}

sub get_text_from_entity {
  my $entity = shift;
  my $type = $entity->mime_type;
  my $body = $entity->bodyhandle;
  if ($type =~ /^text\/plain/i && defined($body)) {
    my $txt = $body->as_string;
    my $len = length $txt;
    return ($len, $txt);
  } elsif ($type =~ /^(?:multipart|message)\/.+/i) {
    my @parts = $entity->parts;
    foreach (@parts) {
      my ($len, $txt) = ::get_text_from_entity $_;
      return ($len, $txt) if $len >= 0;
    }
  }
  return (-1, '');
}

sub get_text_from_multitype {
  my $data = shift;
  my $mimeparser = new MIME::Parser;
  $mimeparser->output_to_core(1);
  $mimeparser->tmp_to_core(1);
  return get_text_from_entity($mimeparser->parse_data($data));
}

sub get_unused_file {
  my $prefix = shift;
  my $i = 0;
  my $filename = sprintf '%s.%03d', $prefix, $i++;
  $filename = sprintf '%s.%03d', $prefix, $i++ while (-e $filename);
  return $filename;
}

sub check_peer {
  my @peer = ([sockaddr_in($_[0])], [sockaddr_in($_[1])]);
  return 1 if $peer[0][0] == $peer[1][0] && inet_ntoa($peer[0][1]) eq inet_ntoa($peer[1][1]);
  return 0;
}

sub mailqueue_add {
  my $list = shift;
  my $authid = shift;
  my $recv_mail = shift;
  for (@$list) {
    next if $_->{'id'} ne $authid;
    push @{$_->{'sendqueue'}}, $recv_mail;
  }
}

my $xmpp_cmd_session = 0;

sub get_xmpp_cmd_session {
  my $id = @{[gettimeofday]}[0];
  $id .= '-';
  $id .= $xmpp_cmd_session++;
  return $id;
}

sub get_xmpp_get_fieldlist {
  # NOTE wantarray doesn't work correctly on callback functions
  my $form = shift;
  my @ret = $form->GetFields;
  return @ret;
}

sub exit_handler {
  $running = 0;
}

GetOptions(
  \%cmdline_options,
  'help|h',
  'man',
  'config-file=s',
  'daemon',
  'log-out=s',
  'log-err=s',
  'pid-file=s',
  'server-host=s',
  'server-port=i',
  'add-authentication=s@',
  'socket-debug',
  'use-mysql',
  'mysql-database=s',
  'mysql-sock=s',
  'use-csv',
  'csv-dir=s',
  'csv-file=s',
  'ssl-ca-file=s',
  'use-xmpp',
  'xmpp-debug',
  'xmpp-host=s',
  'xmpp-user=s',
  'xmpp-password=s',
  'jid-remote=s@',
  'use-smtp',
  'smtp-host=s',
  'smtp-domain=s',
  'smtp-port=i',
  'smtp-ssl',
  'smtp-auth=s',
  'smtp-username=s',
  'smtp-password=s',
  'verify-pop',
  'pop-host=s',
  'pop-username=s',
  'pop-password=s',
  'pop-storage=s',
  'pop-interval=i',
  'mail-addr-local=s',
  'mail-addr-remote=s@',
);

$show_help = $cmdline_options{'help'} if exists $cmdline_options{'help'};
$show_help = $cmdline_options{'h'} if exists $cmdline_options{'h'};
$show_man = $cmdline_options{'man'} if exists $cmdline_options{'man'};

if (exists $cmdline_options{'config-file'} && length $cmdline_options{'config-file'}) {
  my $cfgdata = Config::IniFiles->new(
    -file           => $cmdline_options{'config-file'},
    #-fallback       => 'general',
    -nocase         => 1
    #-nomultiline    => 0
  ) or die 'Error reading config file';
  $verbose_level        = $cfgdata->val('general',  'verbose',      $verbose_level);
  $run_daemon           = config_boolean
                          $cfgdata->val('general',  'daemon',       $run_daemon);
  $log_out              = $cfgdata->val('general',  'logfileout',   $log_out);
  $log_err              = $cfgdata->val('general',  'logfileerr',   $log_err);
  $pidfile              = $cfgdata->val('general',  'pidfile',      $pidfile);
  $listening_host       = $cfgdata->val('server',   'host',         $listening_host);
  $listening_port       = int
                          $cfgdata->val('server',   'port',         $listening_port);
  push(@authentication,   $cfgdata->val('server',   'auth'));
  $socket_debug         = config_boolean
                          $cfgdata->val('server',   'debug',        $socket_debug);
  $use_mysql            = config_boolean
                          $cfgdata->val('mysql',    'enable',       $use_mysql);
  $mysql_db             = $cfgdata->val('mysql',    'database',     $mysql_db);
  $mysql_socket         = $cfgdata->val('mysql',    'socket',       $mysql_socket);
  $use_csv              = config_boolean
                          $cfgdata->val('csv',      'enable',       $use_csv);
  $csv_dir              = $cfgdata->val('csv',      'dir',          $csv_dir);
  $csv_file             = $cfgdata->val('csv',      'file',         $csv_file);
  $ssl_ca_file          = $cfgdata->val('ssl',      'cafile',       $ssl_ca_file);
  $use_xmpp             = config_boolean
                          $cfgdata->val('xmpp',     'enable',       $use_xmpp);
  $xmpp_debug           = config_boolean
                          $cfgdata->val('xmpp',     'debug',        $xmpp_debug);
  $xmpp_domain          = $cfgdata->val('xmpp',     'host',         $xmpp_domain);
  $xmpp_user            = $cfgdata->val('xmpp',     'user',         $xmpp_user);
  $xmpp_password        = $cfgdata->val('xmpp',     'pass',         $xmpp_password);
  push(@xmpp_remote_jid,  $cfgdata->val('xmpp',     'jidremote'));
  $use_smtp             = config_boolean
                          $cfgdata->val('smtp',     'enable',       $use_smtp);
  $smtp_host            = $cfgdata->val('smtp',     'host',         $smtp_host);
  $smtp_domain          = $cfgdata->val('smtp',     'domain',       $smtp_domain);
  $smtp_port            = int
                          $cfgdata->val('smtp',     'port',         $smtp_port);
  $smtp_ssl             = config_boolean
                          $cfgdata->val('smtp',     'ssl',          $smtp_ssl);
  $smtp_auth_type       = $cfgdata->val('smtp',     'auth',         $smtp_auth_type);
  $smtp_auth_user       = $cfgdata->val('smtp',     'user',         $smtp_auth_user);
  $smtp_auth_pass       = $cfgdata->val('smtp',     'pass',         $smtp_auth_pass);
  $use_pop3             = config_boolean
                          $cfgdata->val('pop',      'enable',       $use_pop3);
  $pop3_host            = $cfgdata->val('pop',      'host',         $pop3_host);
  $pop3_user            = $cfgdata->val('pop',      'user',         $pop3_user);
  $pop3_pass            = $cfgdata->val('pop',      'pass',         $pop3_pass);
  $pop3_file            = $cfgdata->val('pop',      'storage',      $pop3_file);
  $pop3_interval        = int
                          $cfgdata->val('pop',      'interval',     $pop3_interval);
  $mail_local_address   = $cfgdata->val('mail',     'localaddr',    $mail_local_address);
  push(@mail_remote_address, $cfgdata->val('mail',  'remoteaddr'));
}

$run_daemon = $cmdline_options{'daemon'} if exists $cmdline_options{'daemon'};
$log_out = $cmdline_options{'log-out'} if exists $cmdline_options{'log-out'};
$log_err = $cmdline_options{'log-err'} if exists $cmdline_options{'log-err'};
$pidfile = $cmdline_options{'pid-file'} if exists $cmdline_options{'pid-file'};
$listening_host = $cmdline_options{'server-host'} if exists $cmdline_options{'server-host'};
$listening_port = $cmdline_options{'server-port'} if exists $cmdline_options{'server-port'};
push(@authentication, @{$cmdline_options{'add-authentication'}}) if exists $cmdline_options{'add-authentication'};
$socket_debug = $cmdline_options{'socket-debug'} if exists $cmdline_options{'socket-debug'};
$use_mysql = $cmdline_options{'use-mysql'} if exists $cmdline_options{'use-mysql'};
$mysql_db = $cmdline_options{'mysql-database'} if exists $cmdline_options{'mysql-database'};
$mysql_socket = $cmdline_options{'mysql-sock'} if exists $cmdline_options{'mysql-sock'};
$use_csv = $cmdline_options{'use-csv'} if exists $cmdline_options{'use-csv'};
$csv_dir = $cmdline_options{'csv-dir'} if exists $cmdline_options{'csv-dir'};
$csv_file = $cmdline_options{'csv-file'} if exists $cmdline_options{'csv-file'};
$ssl_ca_file = $cmdline_options{'ssl-ca-file'} if exists $cmdline_options{'ssl-ca-file'};
$use_xmpp = $cmdline_options{'use-xmpp'} if exists $cmdline_options{'use-xmpp'};
$xmpp_debug = $cmdline_options{'xmpp-debug'} if exists $cmdline_options{'xmpp-debug'};
$xmpp_domain = $cmdline_options{'xmpp-host'} if exists $cmdline_options{'xmpp-host'};
$xmpp_user = $cmdline_options{'xmpp-user'} if exists $cmdline_options{'jid-local'};
$xmpp_password = $cmdline_options{'xmpp-password'} if exists $cmdline_options{'xmpp-password'};
push(@xmpp_remote_jid, @{$cmdline_options{'jid-remote'}}) if exists $cmdline_options{'jid-remote'};
$use_smtp = $cmdline_options{'use-smtp'} if exists $cmdline_options{'use-smtp'};
$smtp_host = $cmdline_options{'smtp-host'} if exists $cmdline_options{'smtp-host'};
$smtp_domain = $cmdline_options{'smtp-domain'} if exists $cmdline_options{'smtp-domain'};
$smtp_port = $cmdline_options{'smtp-port'} if exists $cmdline_options{'smtp-port'};
$smtp_ssl = $cmdline_options{'smtp-ssl'} if exists $cmdline_options{'smtp-ssl'};
$smtp_auth_type = $cmdline_options{'smtp-auth'} if exists $cmdline_options{'smtp-auth'};
$smtp_auth_user = $cmdline_options{'smtp-username'} if exists $cmdline_options{'smtp-username'};
$smtp_auth_pass = $cmdline_options{'smtp-password'} if exists $cmdline_options{'smtp-password'};
$use_pop3 = $cmdline_options{'verify-pop'} if exists $cmdline_options{'verify-pop'};
$pop3_host = $cmdline_options{'pop-host'} if exists $cmdline_options{'pop-host'};
$pop3_user = $cmdline_options{'pop-username'} if exists $cmdline_options{'pop-username'};
$pop3_pass = $cmdline_options{'pop-password'} if exists $cmdline_options{'pop-password'};
$pop3_file = $cmdline_options{'pop-storage'} if exists $cmdline_options{'pop-storage'};
$pop3_interval = $cmdline_options{'pop-interval'} if exists $cmdline_options{'pop-interval'};
$mail_local_address = $cmdline_options{'mail-addr-local'} if exists $cmdline_options{'mail-addr-local'};
push(@mail_remote_address, @{$cmdline_options{'mail-addr-remote'}}) if exists $cmdline_options{'mail-addr-remote'};

pod2usage(1) if $show_help;
pod2usage(-exitstatus => 0, -verbose => 2) if $show_man;

my @authentication_list = ();
my $server_uuid = 1;

for (@authentication) {
  if ($_ =~ /^([^:;]+):([^;]+)$/) {
      push @authentication_list, {'id' => $1, 'password' => $2,
                                  'peer' => undef, 'lastcount' => undef,
                                  'imsi' => undef, 'signal' => undef,
                                  'status' => {'gsm' => undef, 'ip' => undef},
                                  'chanstate' => undef,
                                  'sendmsg' => undef, 'sendqueue' => []};
  } else {
      die "Invalid authentication parameters: $_";
  }
}

my @mail_remote_list = ();

for (@mail_remote_address) {
  if ($_ =~ /^([^:;]+):(.+)$/) {
    push @mail_remote_list, {'id' => $1, 'mailaddr' => $2};
    die "Invalid e-mail address: $2" if $2 !~ /^[-a-zA-Z0-9._%]+@(?:(?:(?:[a-zA-Z0-9][-a-zA-Z0-9]*)?[a-zA-Z0-9])[.])*(?:[a-zA-Z][-a-zA-Z0-9]*[a-zA-Z0-9]|[a-zA-Z])[.]?$/;
  } else {
    die "Invalid remove e-mail parameter: $_"
  }
}

if ($run_daemon) {
  for (@INC) {
    next if $_ ne '.';
    $_ = getcwd;
  }
  chdir '/' or die "Failed to change cwd to /";
  defined(my $daemon_pid = fork) or die "Cannot send process to background";
  exit if $daemon_pid;
  POSIX::setsid or die "Cannot start new process session";
  open(FH, '<', '/dev/null') or die "Cannot open /dev/null";
  open(STDIN, '<&', \*FH) or die "Cannot redirect STDIN to NULL";
  close(FH);
  open(STDOUT, '>', '/dev/null') or die "Cannot redirect STDOUT to NULL" if !length $log_out;
  open(STDERR, '>', '/dev/null') or die "Cannot redirect STDERR to NULL" if !length $log_err;
  #umask 0;
}

open STDOUT, '>', $log_out if length $log_out;
open STDERR, '>', $log_err if length $log_err;

if (length $pidfile) {
  open PIDFILE, '>', $pidfile or die "Cannot write PID file";
  print PIDFILE "$$\n";
  close PIDFILE;
}

if ($use_mysql) {
  $dsn = "DBI:mysql:database=$mysql_db;mysql_socket=$mysql_socket";
  $dbh = DBI->connect($dsn, 'root') or die $DBI::errstr;
  $dbh->{'mysql_auto_reconnect'} = 1;
}

if ($use_csv) {
  $csvh = DBI->connect("DBI:CSV:f_dir=$csv_dir:") or die $DBI::errstr;
  $csvh->{'csv_tables'}->{'sms'} = {'file' => "$csv_dir/$csv_file"};
  if (! -e "$csv_dir/$csv_file") {
    $csvh->do('CREATE TABLE sms (authid TEXT, cid_number TEXT, cid_name TEXT, msg_date INTEGER, tz INTEGER, message TEXT)') or die $DBI::errstr;
  }
}

my @xmpp_remote_jid_list = ();

if ($use_xmpp) {
  require Net::XMPP;
  require Net::XMPP::XEP;
  sub add_xmpp_form_error {
    my $reply = shift;
    my $errstr = shift;
    my $note = $reply->{CHILDREN}->[0]->AddNote();
    $note->SetType('error');
    $note->SetMessage($errstr) if defined $errstr;
    return $reply;
  }
  for (@xmpp_remote_jid) {
    if ($_ =~ /^([^:;]+):([^@\/<>'"]+@(?:(?:(?:(?:(?:[a-zA-Z0-9][-a-zA-Z0-9]*)?[a-zA-Z0-9])[.])*(?:[a-zA-Z][-a-zA-Z0-9]*[a-zA-Z0-9]|[a-zA-Z])[.]?)|(?:[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+)))$/) {
      push @xmpp_remote_jid_list, {'id' => $1, 'jid' => $2, 'command' => []};
    } else {
      die "Invalid authentication server ID/JabberID pair: $_";
    }
  }
  my $xmpp_component = $xmpp_domain;
  if ($xmpp_user =~ /^([^@\/<>'"]+)@((?:(?:(?:(?:[a-zA-Z0-9][-a-zA-Z0-9]*)?[a-zA-Z0-9])[.])*(?:[a-zA-Z][-a-zA-Z0-9]*[a-zA-Z0-9]|[a-zA-Z])[.]?)|(?:[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+))$/) {
    $xmpp_component = $2;
    $xmpp_user = $1;
  }
  $xmpp = new Net::XMPP::Client();
  #$xmpp->SetMessageCallBacks(normal => sub {
  #  my $session = shift;
  #  my $message = shift;
  #  my $from = $message->GetFrom("jid");
  #  my $to = $message->GetTo("jid");
  #  print 'XMPP Message [' . $from->GetJID('full') . '] => [' . $to->GetJID('full') . ']: (' . $message->GetSubject() . '): ' . $message->GetBody() . "\n";
  #  return if $to->GetJID("base") ne "${xmpp_user}@${xmpp_component}" || $message->GetSubject() !~ /^\+?[0-9]+$/;
  #  for (@xmpp_remote_jid_list) {
  #    next if $_->{jid} ne $from->GetJID("base");
  #    my $authid = $_->{id};
  #    for (@authentication_list) {
  #      next if $_->{'id'} ne $authid;
  #      my %recv_mail = (subject => $message->GetSubject(), message_text => $message->GetBody());
  #      $recv_mail{message_length} = length $recv_mail{message_text};
  #      push @{$_->{'sendqueue'}}, \%recv_mail;
  #      print "[" . $from->GetJID("base") . "] QUEUE SMS(${recv_mail{subject}}): ${recv_mail{message_text}}\n";
  #      last;
  #    }
  #  }
  #});
  $xmpp->SetCallBacks(message => sub {
    my $session = shift;
    my $message = shift;
    my $from = $message->GetFrom("jid");
    my $to = $message->GetTo("jid");
    if ($message->GetType() =~ /^(?:normal)?$/i) {
      print 'XMPP Message [' . $from->GetJID('full') . '] => [' . $to->GetJID('full') . ']: (' . $message->GetSubject() . '): ' . $message->GetBody() . "\n";
      return if $to->GetJID("base") ne "${xmpp_user}\@${xmpp_component}" || $message->GetSubject() !~ /^\+?[0-9]+$/;
      for (@xmpp_remote_jid_list) {
        next if $_->{jid} ne $from->GetJID("base");
        my $authid = $_->{id};
        for (@authentication_list) {
          next if $_->{'id'} ne $authid;
          my %recv_mail = (subject => $message->GetSubject(), message_text => $message->GetBody());
          $recv_mail{message_length} = length $recv_mail{message_text};
          push @{$_->{'sendqueue'}}, \%recv_mail;
          print "[" . $from->GetJID("base") . "] QUEUE SMS(${recv_mail{subject}}): ${recv_mail{message_text}}\n";
          last;
        }
      }
    } else {
      print 'Unhandle XMPP Message type ' . $message->GetType() . ' [' . $from->GetJID('full') . '] => [' . $to->GetJID('full') . ']: ' . $message->GetBody() . "\n";
    }
  },
                      iq => sub {
    my $session = shift;
    my $iq = shift;
    my @available_services = ({node => 'sms', name => 'Send SMS Service', run => sub {
      my $jid = shift;
      my $query = shift;
      my $cmd = $query->GetQuery();
      my $cmdsession = undef;
      my $reply;
      if (!$cmd->DefinedSessionID()) {
        # NOTE check $cmd->DefinedAction() && $cmd->GetAction() eq 'execute'
        $reply = $query->Reply();
        $reply->{CHILDREN}->[0]->SetSessionID(get_xmpp_cmd_session());
        $reply->{CHILDREN}->[0]->SetNode('sms');
        $reply->{CHILDREN}->[0]->SetStatus('executing');
        shift @{$jid->{command}} if scalar(@{$jid->{command}}) > 100; # Store only last 100 requests
        push @{$jid->{command}}, {session => $reply->{CHILDREN}->[0]->GetSessionID(),
                                  node => 'sms',
                                  phase => 1};
        my $actions = $reply->{CHILDREN}->[0]->AddFormAction();
        $actions->SetComplete();
        $actions->SetExecute('complete');
        my $form = $reply->{CHILDREN}->[0]->AddForm();
        $form->SetTitle('Send SMS Service');
        $form->SetInstructions('Fill all fields below with destination phone number and SMS text message');
        my $formfield = $form->AddField();
        $formfield->SetVar('phone');
        $formfield->SetLabel('Phone number');
        $formfield->SetType('text-single');
        $formfield->SetRequired();
        $formfield = $form->AddField();
        $formfield->SetVar('message');
        $formfield->SetLabel('Text message');
        $formfield->SetType('text-multi');
        print "[$jid->{jid}] Request to run sms ad-hoc command\n" if $xmpp_debug;
        return $reply;
      }
      for (@{$jid->{command}}) {
        next if $cmd->GetSessionID() ne $_->{session} || !$_->{phase};
        $reply = $query->Reply();
        $reply->{CHILDREN}->[0]->SetSessionID($_->{session});
        $reply->{CHILDREN}->[0]->SetNode('sms');
        $cmdsession = $_;
        last;
      }
      if (!defined $cmdsession) {
        $reply->{CHILDREN}->[0]->SetStatus('completed');
        print "[$jid->{jid}] Request on invalid session: " . $cmd->GetSessionID() . "\n" if $xmpp_debug;
        return add_xmpp_form_error($reply, 'Command was sent with invalid session id');
      }
      if ($cmd->DefinedAction() && $cmd->GetAction() eq 'cancel') {
        $reply->{CHILDREN}->[0]->SetStatus('canceled');
        $cmdsession->{phase} = 0;
        print "[$jid->{jid}] Cancel sms ad-hoc command\n" if $xmpp_debug;
        return $reply;
      }
      if (!$cmd->DefinedAction() && $cmd->DefinedForms()) {
        $reply->{CHILDREN}->[0]->SetStatus('completed');
        $cmdsession->{phase} = 0;
        my $form = undef;
        my $formlist = $cmd->GetForms();
        if (ref($formlist) =~ /^Net::XMPP::.+$/) {
          $form = $formlist;
        } elsif (ref($formlist) eq 'SCALAR') {
          $form = $$formlist;
        } elsif (ref($formlist) eq 'ARRAY') {
          for (@{$formlist}) {
            next if $_->GetType() ne 'submit';
            $form = $_;
            last;
          }
        }
        return add_xmpp_form_error($reply, 'Missing submit form data') if !defined $form;
        my %recv_mail;
        for (get_xmpp_get_fieldlist($form)) {
          next if !$_->DefinedValue() || !$_->DefinedVar();
          $recv_mail{subject} = $_->GetValue() if $_->GetVar() eq 'phone';
          $recv_mail{message_text} = $_->GetValue() if $_->GetVar() eq 'message';
        }
        return add_xmpp_form_error($reply, 'Phone number field is required') if !exists $recv_mail{subject};
        $recv_mail{message_text} = '' if !exists $recv_mail{message_text};
        $recv_mail{message_length} = length $recv_mail{message_text};
        for (@authentication_list) {
          next if $_->{id} ne $jid->{id};
          push @{$_->{'sendqueue'}}, \%recv_mail;
          print "[$jid->{jid}] QUEUE SMS(${recv_mail{subject}}): ${recv_mail{message_text}}\n";
          last;
        }
        my $note = $reply->{CHILDREN}->[0]->AddNote();
        $note->SetType('info');
        $note->SetMessage('SMS message was queued to send');
      } else {
        $reply->{CHILDREN}->[0]->SetStatus('completed');
        return add_xmpp_form_error($reply, 'Missing submit form data');
      }
      return $reply;
    }},
                              {node => 'ussd', name => 'Send USSD Command', run => sub {
      my $jid = shift;
      my $query = shift;
      my $cmd = $query->GetQuery();
      my $cmdsession = undef;
      my $reply;
      if (!$cmd->DefinedSessionID()) {
        # NOTE check $cmd->DefinedAction() && $cmd->GetAction() eq 'execute'
        $reply = $query->Reply();
        $reply->{CHILDREN}->[0]->SetSessionID(get_xmpp_cmd_session());
        $reply->{CHILDREN}->[0]->SetNode('ussd');
        $reply->{CHILDREN}->[0]->SetStatus('completed');
        shift @{$jid->{command}} if scalar(@{$jid->{command}}) > 100; # Store only last 100 requests
        push @{$jid->{command}}, {session => $reply->{CHILDREN}->[0]->GetSessionID(),
                                  node => 'ussd',
                                  phase => 0};
        # NOTE UNIMPLEMENTED YET
        my $note = $reply->{CHILDREN}->[0]->AddNote();
        $note->SetType('warn');
        $note->SetMessage('Method not implemented yet');
        print "[$jid->{jid}] Request to run ussd ad-hoc command\n" if $xmpp_debug;
        return $reply;
      }
      for (@{$jid->{command}}) {
        next if $cmd->GetSessionID() ne $_->{session} || !$_->{phase};
        $reply = $query->Reply();
        $reply->{CHILDREN}->[0]->SetSessionID($_->{session});
        $reply->{CHILDREN}->[0]->SetNode('sms');
        $cmdsession = $_;
        last;
      }
      if (!defined $cmdsession) {
        $reply->{CHILDREN}->[0]->SetStatus('completed');
        print "[$jid->{jid}] Request on invalid session: " . $cmd->GetSessionID() . "\n" if $xmpp_debug;
        return add_xmpp_form_error($reply, 'Command was sent with invalid session id');
      }
      if ($cmd->DefinedAction() && $cmd->GetAction() eq 'cancel') {
        $reply->{CHILDREN}->[0]->SetStatus('canceled');
        $cmdsession->{phase} = 0;
        print "[$jid->{jid}] Cancel ussd ad-hoc command\n" if $xmpp_debug;
        return $reply;
      }
      $reply->{CHILDREN}->[0]->SetStatus('completed');
      my $note = $reply->{CHILDREN}->[0]->AddNote();
      $note->SetType('warn');
      $note->SetMessage('Method not implemented yet');
      return $reply;
    }});
    my $xmlns = $iq->GetQueryXMLNS();
    # NOTE Switch doesn't work correctly here
    if ($xmlns eq 'http://jabber.org/protocol/disco#info') {
      XMLNS: {
        my $query = $iq->GetQuery();
        last XMLNS if $iq->GetType() ne 'get';
        my $reply = $iq->Reply();
        if ($query->DefinedNode()) {
          my $service = undef;
          for (@available_services) {
            next if $query->GetNode() ne $_->{node};
            $service = $_;
            last;
          }
          if (defined $service) {
            print "[" . $iq->GetFrom("jid")->GetJID("base") . "] Request service '$service->{node}' information\n" if $xmpp_debug;
            my $identity = $reply->{CHILDREN}->[0]->AddIdentity();
            $identity->SetName($service->{name});
            $identity->SetCategory('automation');
            $identity->SetType('command-node');
            my $feature = $reply->{CHILDREN}->[0]->AddFeature();
            $feature->SetVar('http://jabber.org/protocol/commands');
            $feature = $reply->{CHILDREN}->[0]->AddFeature();
            $feature->SetVar('jabber:x:data');
          } else {
            print "[" . $iq->GetFrom("jid")->GetJID("base") . "] Service information '$service->{node}' not found\n" if $xmpp_debug;
            $reply->SetErrorCode(404); # TODO Include <error type='cancel'> ... </error>
          }
        } else {
          print "[" . $iq->GetFrom("jid")->GetJID("base") . "] Listing node feature\n" if $xmpp_debug;
          my $feature = $reply->{CHILDREN}->[0]->AddFeature();
          $feature->SetVar('http://jabber.org/protocol/commands');
        }
        $xmpp->Send($reply);
      }
    } elsif ($xmlns eq 'http://jabber.org/protocol/disco#items') {
      XMLNS: {
        my $query = $iq->GetQuery();
        last XMLNS if $iq->GetType() ne 'get';
        my $reply = $iq->Reply();
        last XMLNS if !$query->DefinedNode() && $query->GetNode() ne 'http://jabber.org/protocol/commands';
        print "[" . $iq->GetFrom("jid")->GetJID("base") . "] Listing ad-hoc commands\n" if $xmpp_debug;
        $reply = $iq->Reply();
        $reply->{CHILDREN}->[0]->SetNode('http://jabber.org/protocol/commands');
        for (@available_services) {
          my $item = $reply->{CHILDREN}->[0]->AddItem();
          $item->SetJID($reply->GetFrom("jid"));
          $item->SetNode($_->{node});
          $item->SetName($_->{name});
        }
        $xmpp->Send($reply);
      }
    } elsif ($xmlns eq 'http://jabber.org/protocol/commands') {
      XMLNS: {
        my $query = $iq->GetQuery();
        last XMLNS if $iq->GetType() ne 'set' || !$query->DefinedNode();
        my $reply;
        my $service = undef;
        for (@available_services) {
          next if $query->GetNode() ne $_->{node};
          $service = $_;
          last;
        }
        if (defined $service) {
          my $authuser = undef;
          my $from = $iq->GetFrom("jid");
          for (@xmpp_remote_jid_list) {
            next if $_->{jid} ne $from->GetJID("base");
            $authuser = $_;
            last;
          }
          if (defined $authuser) {
            $reply = $service->{run}($authuser, $iq);
          } else {
            $reply = $iq->Reply();
            $reply->SetErrorCode(403);
          }
        } else {
          $reply = $iq->Reply();
          $reply->SetErrorCode(404);
        }
        $xmpp->Send($reply);
      }
    }
  });
  $xmpp->Connect(hostname => $xmpp_domain,
                 #port => 5222,
                 tls => 0,
                 componentname => $xmpp_component,
                 connectiontype => 'tcpip') or die "Failed to connect to XMPP server: $!";
  my @xmpp_auth = $xmpp->AuthSend(username => $xmpp_user,
                                  password => $xmpp_password,
                                  resource => 'sms-server') or die "Failed to authenticate on XMPP server: $!";
  die "Incorrect XMPP authentication: $xmpp_auth[1]" if $xmpp_auth[0] ne 'ok';
  $xmpp->PresenceSend(show => 'available');
  my %xmpp_roster = $xmpp->RosterGet();
  for (@xmpp_remote_jid_list) {
    if (exists $xmpp_roster{$_->{jid}}) {
      switch ($xmpp_roster{$_->{jid}}->{subscription}) {
        case 'to' {
          $xmpp->Subscription(type => 'subscribed', to => $_->{jid});
          print "Authorize $_->{jid} on him list\n";
        }
        case 'from' {
          $xmpp->Subscription(type => 'subscribe', to => $_->{jid});
          print "Request authorization for $_->{jid}\n";
        }
      }
    } else {
      print "Adding $_->{jid} on my list\n";
      $xmpp->RosterAdd(jid => $_->{jid});
      $xmpp->Subscription(type => 'subscribe', to => $_->{jid});
      $xmpp->Subscription(type => 'subscribed', to => $_->{jid});
    }
  }
}

$mail_local_address = "$smtp_auth_user\@$smtp_domain" if (($use_smtp || $use_pop3) && !length($mail_local_address) && length($smtp_auth_user));

my %timers = ('smtp' => [gettimeofday], 'pop' => [gettimeofday]);
my ($SMTP_Module, @smtp_auth_args, %smtp_module_args);

if ($use_smtp) {
  $SMTP_Module = $smtp_ssl ? 'Net::SMTPS' : 'Net::SMTP_auth';
  eval "require $SMTP_Module";
  die 'Invalid SMTP host' if !($smtp_host =~ /^(?:(?:(?:(?:(?:[a-zA-Z0-9][-a-zA-Z0-9]*)?[a-zA-Z0-9])[.])*(?:[a-zA-Z][-a-zA-Z0-9]*[a-zA-Z0-9]|[a-zA-Z])[.]?)|(?:[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+))$/);
  $smtp_domain = $smtp_host if !length($smtp_domain);
  if (!$smtp_auth_type =~ /^(?:CRAM_MD5|DIGEST_MD5|LOGIN|PLAIN)$/) {
    print STDERR "Unsupported SMTP Authentication: $smtp_auth_type\n";
    print STDERR "Using 'PLAIN' instead\n";
    $smtp_auth_type = 'PLAIN';
  }
  $smtp_auth_pass = '' if (!length($smtp_auth_user));
  die "Invalid e-mail address: $mail_local_address" if (!$mail_local_address =~ /^[-a-zA-Z0-9._%]+@(?:(?:(?:[a-zA-Z0-9][-a-zA-Z0-9]*)?[a-zA-Z0-9])[.])*(?:[a-zA-Z][-a-zA-Z0-9]*[a-zA-Z0-9]|[a-zA-Z])[.]?$/);
  %smtp_module_args = (
    'Hello'     => $smtp_domain,
    'AutoHello' => 1,
    'Port'      => ($smtp_port < 1 || $smtp_port > 65535 ? ($smtp_ssl ? 465 : 25) : $smtp_port)
  );
  if ($smtp_ssl) {
    $smtp_module_args{doSSL} = 'ssl';
    $smtp_module_args{SSL_ca_file} = $ssl_ca_file if length $ssl_ca_file;
  }
  $smtp = $SMTP_Module->new(
    $smtp_host,
    %smtp_module_args
  ) or die 'Error connecting to SMTP server';
  @smtp_auth_args = $smtp_ssl ? ($smtp_auth_user, $smtp_auth_pass, $smtp_auth_type) : ($smtp_auth_type, $smtp_auth_user, $smtp_auth_pass);
  $smtp->auth(@smtp_auth_args) or die 'Error on authenticate SMTP connection';
}

if ($use_pop3) {
  die 'Invalid POP3 host' if !($pop3_host =~ /^(?:(?:(?:(?:(?:[a-zA-Z0-9][-a-zA-Z0-9]*)?[a-zA-Z0-9])[.])*(?:[a-zA-Z][-a-zA-Z0-9]*[a-zA-Z0-9]|[a-zA-Z])[.]?)|(?:[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+))$/);
  $pop3_pass = '' if (!length($pop3_user));
  die "Invalid e-mail address: $mail_local_address" if (length($mail_local_address) && !$mail_local_address =~ /^[-a-zA-Z0-9._%]+@(?:(?:(?:[a-zA-Z0-9][-a-zA-Z0-9]*)?[a-zA-Z0-9])[.])*(?:[a-zA-Z][-a-zA-Z0-9]*[a-zA-Z0-9]|[a-zA-Z])[.]?$/);
  $pop3 = Mail::POP3Client->new(HOST => $pop3_host);
  if (length($pop3_user)) {
    $pop3->User($pop3_user);
    $pop3->Pass($pop3_pass) if length($pop3_pass);
  }
  $pop3->Connect() or die 'POP3 Error: ' . $pop3->Message();
  if ($pop3_interval < 10) {
    print "An interval of '$pop3_interval' is too short, setting it to '30'";
    $pop3_interval = 30;
  }
  $timers{'pop'}[0] -= $pop3_interval;
}

my $sighandler = POSIX::SigAction->new('exit_handler', POSIX::SigSet->new(), &POSIX::SA_NODEFER);
POSIX::sigaction(&POSIX::SIGINT, $sighandler);
POSIX::sigaction(&POSIX::SIGTERM, $sighandler);

$serversocket = IO::Socket::INET->new(
  LocalHost => $listening_host,
  LocalPort => $listening_port,
  Proto => 'udp',
  Blocking => 0
) or die 'Cannot create socket object';
$sockset = IO::Select->new();
$sockset->add($serversocket);

$running = 1;

my @ready;
my %sockpeer = ('addr' => undef, 'port' => undef, 'name' => undef);
my $sockdata;
my $socktimeout = 6;
$socktimeout = 3 if $use_xmpp && $xmpp;

while ($running) { # Main program loop
  if ($use_smtp && defined $smtp) {
    $waittime = tv_interval($timers{'smtp'}, [gettimeofday]);
    if ($waittime > 60) {
      $smtp->quit;
      $smtp = undef;
    }
  }
  while (scalar($sockset->can_read($socktimeout))) {
    die 'Socket unexpected closed' if !$serversocket->recv($sockdata, 16384);
    $sockpeer{'addr'} = $serversocket->peeraddr;
    $sockpeer{'host'} = $serversocket->peerhost;
    $sockpeer{'port'} = $serversocket->peerport;
    $sockpeer{'name'} = $serversocket->peername;
    print "SOCKET $sockpeer{host}:$sockpeer{port} << $sockdata\n" if $socket_debug;
    switch ($sockdata) {
      case m/^req:(-?\d+);id:([^:;]+);pass:([^;]+);num:([0-9a-zA-Z]*);signal:([+-]?[0-9.]+);gsm_status:(LOGIN|LOGOUT);voip_status:(LOGIN|LOGOUT);$/ {
        next if $sockdata !~ m/^req:(-?\d+);id:([^:;]+);pass:([^;]+);num:([0-9a-zA-Z]*);signal:([+-]?[0-9.]+);gsm_status:(LOGIN|LOGOUT);voip_status:(LOGIN|LOGOUT);$/;
        my $regstatus = 1;
        for (@authentication_list) {
          next if $_->{'id'} ne $2 || $_->{'password'} ne $3;
          $_->{'peer'} = $sockpeer{'name'};
          $_->{'lastcount'} = int $1;
          $_->{'imsi'} = $4;
          $_->{'signal'} = $5;
          $_->{'status'}{'gsm'} = ($6 eq 'LOGIN') ? 1 : 0;
          $_->{'status'}{'ip'} = ($7 eq 'LOGIN') ? 1 : 0;
          $regstatus = 0;
          last;
        }
        $sockdata = "reg:$1;status:$regstatus;\n";
        send($serversocket, $sockdata, 0, $sockpeer{'name'});
        print "SOCKET $sockpeer{host}:$sockpeer{port} >> $sockdata\n" if $socket_debug;
      }
      case m/^PASSWORD (-?\d+)$/ {
        next if $sockdata !~ m/^PASSWORD (-?\d+)$/;
        my $sendid = int $1;
        for (@authentication_list) {
          next if !defined $_->{'sendmsg'} || !defined $_->{'peer'} || !check_peer($_->{'peer'}, $sockpeer{'name'}) ||
                  $_->{'sendmsg'}{'phase'} ne 'BulkSMSRequest' || $_->{'sendmsg'}{'sendid'} != $sendid;
          $_->{'sendmsg'}{'phase'} = 'AuthenticationRequest';
          $sockdata = "PASSWORD $sendid $_->{password}\n";
          send($serversocket, $sockdata, 0, $sockpeer{'name'});
          print "SOCKET $sockpeer{host}:$sockpeer{port} >> $sockdata\n" if $socket_debug;
          last;
        }
      }
      case m/^SEND (-?\d+)$/ {
        next if $sockdata !~ m/^SEND (-?\d+)$/;
        my $sendid = int $1;
        for (@authentication_list) {
          next if !defined $_->{'sendmsg'} || !defined $_->{'peer'} || !check_peer($_->{'peer'}, $sockpeer{'name'}) ||
                  $_->{'sendmsg'}{'phase'} ne 'AuthenticationRequest' || $_->{'sendmsg'}{'sendid'} != $sendid;
          $_->{'sendmsg'}{'phase'} = 'SubmitNumberRequest';
          if (scalar(@{$_->{'sendmsg'}{'phonequeue'}})) {
            $_->{'sendmsg'}{'phonemsg'} = [$_->{'sendmsg'}{'phoneuuid'}++, shift @{$_->{'sendmsg'}{'phonequeue'}}];
            $sockdata = "SEND $sendid $_->{sendmsg}{phonemsg}[0] $_->{sendmsg}{phonemsg}[1]\n";
          } else {
            $sockdata = "DONE $sendid\n";
          }
          send($serversocket, $sockdata, 0, $sockpeer{'name'});
          print "SOCKET $sockpeer{host}:$sockpeer{port} >> $sockdata\n" if $socket_debug;
          last;
        }
      }
      case m/^OK (-?\d+) (-?\d+)\s*$/ {
        next if $sockdata !~ m/^OK (-?\d+) (-?\d+)\s*$/;
        my $sendid = int $1;
        my $telid = int $2;
        for (@authentication_list) {
          next if !defined $_->{'sendmsg'} || !defined $_->{'peer'} || !check_peer($_->{'peer'}, $sockpeer{'name'}) ||
                  $_->{'sendmsg'}{'phase'} ne 'SubmitNumberRequest' || $_->{'sendmsg'}{'sendid'} != $sendid ||
                  $_->{'sendmsg'}{'phonemsg'}[0] != $telid;
          $_->{'sendmsg'}{'phonewait'} = undef if defined $_->{'sendmsg'}{'phonewait'};
          if (scalar(@{$_->{'sendmsg'}{'phonequeue'}})) {
            $_->{'sendmsg'}{'phonemsg'} = [$_->{'sendmsg'}{'phoneuuid'}++, shift @{$_->{'sendmsg'}{'phonequeue'}}];
            $sockdata = "SEND $sendid $_->{sendmsg}{phonemsg}[0] $_->{sendmsg}{phonemsg}[1]\n";
          } else {
            $sockdata = "DONE $sendid\n";
          }
          send($serversocket, $sockdata, 0, $sockpeer{'name'});
          print "SOCKET $sockpeer{host}:$sockpeer{port} >> $sockdata\n" if $socket_debug;
          last;
        }
      }
      case m/^WAIT (-?\d+) (-?\d+)\s*$/ {
        next if $sockdata !~ m/^WAIT (-?\d+) (-?\d+)\s*$/;
        my $sendid = int $1;
        my $telid = int $2;
        for (@authentication_list) {
          next if !defined $_->{'sendmsg'} || !defined $_->{'peer'} || !check_peer($_->{'peer'}, $sockpeer{'name'}) ||
                  $_->{'sendmsg'}{'phase'} ne 'SubmitNumberRequest' || $_->{'sendmsg'}{'sendid'} != $sendid ||
                  $_->{'sendmsg'}{'phonemsg'}[0] != $telid;
          $_->{'sendmsg'}{'phonewait'} = [gettimeofday];
        }
      }
      case m/^ERROR (-?\d+) (-?\d+) errorstatus:(-?\d+)\s*$/ {
        next if $sockdata !~ m/^ERROR (-?\d+) (-?\d+) errorstatus:(-?\d+)\s*$/;
        my $sendid = int $1;
        my $telid = int $2;
        my $errorstatus = 1;
        for (@authentication_list) {
          next if !defined $_->{'sendmsg'} || !defined $_->{'peer'} || !check_peer($_->{'peer'}, $sockpeer{'name'}) ||
                  $_->{'sendmsg'}{'phase'} ne 'SubmitNumberRequest' || $_->{'sendmsg'}{'sendid'} != $sendid ||
                  $_->{'sendmsg'}{'phonemsg'}[0] != $telid;
          $_->{'sendmsg'}{'phonewait'} = undef if defined $_->{'sendmsg'}{'phonewait'};
          if (scalar(@{$_->{'sendmsg'}{'phonequeue'}}) && int $3 == 1) {
            $_->{'sendmsg'}{'phonemsg'} = [$_->{'sendmsg'}{'phoneuuid'}++, shift @{$_->{'sendmsg'}{'phonequeue'}}];
            $sockdata = "SEND $sendid $_->{sendmsg}{phonemsg}[0] $_->{sendmsg}{phonemsg}[1]\n";
          } else {
            $sockdata = "DONE $sendid\n";
          }
          send($serversocket, $sockdata, 0, $sockpeer{'name'});
          print "SOCKET $sockpeer{host}:$sockpeer{port} >> $sockdata\n" if $socket_debug;
          $errorstatus = 0;
          last;
        }
        next if $errorstatus;
      }
      case m/^ERROR (-?\d+) (.+)$/ {
        next if $sockdata !~ m/^ERROR (-?\d+) (.+)$/;
        # Error on initialized session
        my $sendid = int $1;
        for (@authentication_list) {
          next if !defined $_->{'sendmsg'} || !defined $_->{'peer'} || !check_peer($_->{'peer'}, $sockpeer{'name'}) ||
                  $_->{'sendmsg'}{'phase'} ne 'BulkSMSRequest' || $_->{'sendmsg'}{'sendid'} != $sendid;
          #$_->{'sendmsg'} = undef;
          # TODO check if is necessary to end the session
          $sockdata = "DONE $sendid\n";
          send($serversocket, $sockdata, 0, $sockpeer{'name'});
          print "SOCKET $sockpeer{host}:$sockpeer{port} >> $sockdata\n" if $socket_debug;
          last;
        }
      }
      case m/^DONE (-?\d+)$/ {
        next if $sockdata !~ m/^DONE (-?\d+)$/;
        my $sendid = int $1;
        for (@authentication_list) {
          next if !defined $_->{'sendmsg'} || !defined $_->{'peer'} || !check_peer($_->{'peer'}, $sockpeer{'name'}) ||
                  $_->{'sendmsg'}{'sendid'} != $sendid;
          $_->{'sendmsg'} = undef;
        }
      }
      case m/^RECEIVE:(-?\d+);id:([^:;]+);password:([^;]+);srcnum:([^;]*);msg:(.*)/s {
        next if $sockdata !~ m/^RECEIVE:(-?\d+);id:([^:;]+);password:([^;]+);srcnum:([^;]*);msg:(.*)/s;
        my $recvstatus = 1;
        my %recvdata = ('lastcount' => $1, 'id' => $2, 'password' => $3, 'srcnum' => $4, 'msg' => $5);
        my $strnow = POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime);
        for (@authentication_list) {
          next if $_->{'id'} ne $recvdata{'id'} || $_->{'password'} ne $recvdata{'password'};
          if (!defined $_->{'peer'} || !check_peer($_->{'peer'}, $sockpeer{'name'}))
          {
            $recvstatus = 2;
            next;
          }
          $_->{'lastpacket'} = $sockdata;
          if ($verbose_level) {
            print "ReceiveID: $recvdata{lastcount}\n";
            print "CallerID: $recvdata{srcnum}\n";
            print "\t__MESSAGE_START__\n$recvdata{msg}\n\t__MESSAGE_END__\n\n";
          }
          if ($use_mysql && $dbh) {
            my $stmt = <<EOF;
    INSERT INTO recv_sms
        (authid, cid_number, cid_name, msg_date, tz, message)
            VALUES
        (?, ?, NULL, NOW(), 0, ?)
EOF
            $dbh->do($stmt, undef, $recvdata{'id'}, $recvdata{'srcnum'}, $recvdata{'msg'}) or print STDERR "Failed to run query on MySQL: $stmt\n";
          }
          if ($use_csv && $csvh) {
            $csvh->do('INSERT INTO sms VALUES (?, ?, ?, ?, 0, ?)', undef,
                      $recvdata{'id'}, $recvdata{'srcnum'}, undef, $strnow, $recvdata{'msg'}) or
                      print STDERR "Failed to write SMS data to CSV file\n";
          }
          if ($use_xmpp) {
            if (!$xmpp->Connected()) {
              if ($xmpp->Connect(hostname => $xmpp_domain,
                                 #port => 5222,
                                 tls => 0,
                                 componentname => $xmpp_component,
                                 connectiontype => 'tcpip')) {
                @xmpp_auth = $xmpp->AuthSend(username => $xmpp_user,
                                             password => $xmpp_password,
                                             resource => 'sms-server');
                if (@xmpp_auth) {
                  if ($xmpp_auth[0] ne 'ok') {
                    print "Incorrect XMPP authentication: $xmpp_auth[1]\n";
                    $xmpp->Disconnect();
                    delete($xmpp->{PROCESSERROR});
                  } else {
                    $xmpp->PresenceSend(show => 'available');
                  }
                } else {
                  $xmpp->Disconnect();
                  delete($xmpp->{PROCESSERROR});
                  print STDERR "Failed to authenticate on XMPP server: $!\n";
                }
              } else {
                print STDERR "Failed to connect to XMPP server: $!\n";
              }
            }
            if ($xmpp->Connected()) {
              for (@xmpp_remote_jid_list) {
                next if $_->{id} ne $recvdata{'id'};
                print "XMPP message to $_->{jid} from SMS $recvdata{srcnum}\n";
                $xmpp->MessageSend(to => $_->{jid},
                                   subject => "[SMS] Received from $recvdata{srcnum} at $strnow",
                                   body => $recvdata{'msg'}); # or print "Error sending XMPP message to $_->{jid}\n"
              }
            }
          }
          if ($use_smtp) {
            if (!defined $stmt) {
              if ($smtp = $SMTP_Module->new($smtp_host, %smtp_module_args)) {
                if (!$smtp->auth(@smtp_auth_args)) {
                  print STDERR "Error on authenticate SMTP connection\n";
                  $smtp->quit;
                  $smtp = undef;
                }
              } else {
                print STDERR "Error connecting to SMTP server\n";
                $smtp = undef;
              }
            }
            if (defined $smtp) {
              for (@mail_remote_list)
              {
                next if $_->{'id'} ne $recvdata{'id'};
                $smtp->mail($mail_local_address);
                $smtp->to($_->{'mailaddr'});
                $smtp->data;
                $smtp->datasend("From: \"SMS Message Service\" <$mail_local_address>\n");
                $smtp->datasend("To: $_->{mailaddr}\n");
                $smtp->datasend("Subject: [SMS] Received from $recvdata{srcnum} at $strnow\n");
                $smtp->datasend("X-SMS-CallerID: $recvdata{srcnum}\n");
                $smtp->datasend("\n");
                $smtp->datasend($recvdata{'msg'});
                $smtp->dataend;
              }
              $timers{'smtp'} = [gettimeofday];
            }
          }
          $recvstatus = 0;
          last;
        }
        if ($recvstatus) {
          my $errstr = 'Failed';
          switch ($recvstatus) {
            case 1 { $errstr = "not find this id:$recvdata{id}, or password error" }
            case 2 { $errstr = 'not initialized' }
            else   { $errstr = 'unknown error' }
          }
          $sockdata = "RECEIVE $recvdata{lastcount} ERROR $errstr\n";
        } else {
          $sockdata = "RECEIVE $recvdata{lastcount} OK\n";
        }
        send($serversocket, $sockdata, 0, $sockpeer{'name'});
        print "SOCKET $sockpeer{host}:$sockpeer{port} >> $sockdata\n" if $socket_debug;
      }
      case m/^STATE:(-?\d+);id:([^:;]+);password:([^;]+);gsm_remain_state:(IDLE|BUSY)$/ {
        next if $sockdata !~ m/^STATE:(-?\d+);id:([^:;]+);password:([^;]+);gsm_remain_state:(IDLE|BUSY)$/;
        my $regstatus = 1;
        for (@authentication_list) {
          next if $_->{'id'} ne $2 || $_->{'password'} ne $3;
          $_->{'chanstate'} = $4;
          $regstatus = 0;
          last;
        }
        if ($regstatus) { # Got error
          $sockdata = "STATE $1 not find this id";
        } else {
          $sockdata = "STATE $1 OK";
        }
        send($serversocket, $sockdata, 0, $sockpeer{'name'});
        print "SOCKET $sockpeer{host}:$sockpeer{port} >> $sockdata\n" if $socket_debug;
      }
      case m/^RECORD:(-?\d+);id:([^:;]+);password:([^;]+);dir:(\d);num:([^;]*)$/ {
        next if $sockdata !~ m/^RECORD:(-?\d+);id:([^:;]+);password:([^;]+);dir:(\d);num:([^;]*)$/;
        my $regstatus = 1;
        for (@authentication_list) {
          next if $_->{'id'} ne $2 || $_->{'password'} ne $3;
          # TODO
          $regstatus = 0;
          last;
        }
        if ($regstatus) {
          $sockdata = "RECORD $1 not find this id";
        } else {
          $sockdata = "RECORD $1 OK";
        }
        send($serversocket, $sockdata, 0, $sockpeer{'name'});
        print "SOCKET $sockpeer{host}:$sockpeer{port} >> $sockdata\n" if $socket_debug;
      }
      case m/^REMAIN:(-?\d+);id:([^:;]+);password:([^;]+);gsm_remain_time:(\d*)$/ {
        next if $sockdata !~ m/^REMAIN:(-?\d+);id:([^:;]+);password:([^;]+);gsm_remain_time:(\d*)$/;
        my $regstatus = 1;
        for (@authentication_list) {
          next if $_->{'id'} ne $2 || $_->{'password'} ne $3;
          # TODO
          $regstatus = 0;
          last;
        }
        if ($regstatus) {
          $sockdata = "REMAIN $1 OK";
        } else {
          $sockdata = "REMAIN $1 not find this id";
        }
        send($serversocket, $sockdata, 0, $sockpeer{'name'});
        print "SOCKET $sockpeer{host}:$sockpeer{port} >> $sockdata\n" if $socket_debug;
      }
      case m/^EXPIRY:(-?\d+);id:([^:;]+);password:([^;]+);exp:(\d*)$/ {
        next if $sockdata !~ m/^EXPIRY:(-?\d+);id:([^:;]+);password:([^;]+);exp:(\d*)$/;
        my $regstatus = 1;
        for (@authentication_list) {
          next if $_->{'id'} ne $2 || $_->{'password'} ne $3;
          # TODO
          $regstatus = 0;
          last;
        }
        if ($regstatus) {
          $sockdata = "EXPIRY $1 OK";
        } else {
          $sockdata = "EXPIRY $1 not find this id";
        }
        send($serversocket, $sockdata, 0, $sockpeer{'name'});
        print "SOCKET $sockpeer{host}:$sockpeer{port} >> $sockdata\n" if $socket_debug;
      }
      # TODO implements USSD commands
    }
  }
  if ($use_xmpp && $xmpp) {
    if ($xmpp->Connected()) {
      my $xmpp_status = $xmpp->Process($socktimeout);
      while ($xmpp_status) {
        $xmpp_status = $xmpp->Process($socktimeout);
      }
      $xmpp->Disconnect() if !defined $xmpp_status;
    } else {
      delete($xmpp->{PROCESSERROR}) if exists $xmpp->{PROCESSERROR};
      if ($xmpp->Connect(hostname => $xmpp_domain,
                         #port => 5222,
                         tls => 0,
                         componentname => $xmpp_component,
                         connectiontype => 'tcpip')) {
        @xmpp_auth = $xmpp->AuthSend(username => $xmpp_user,
                                     password => $xmpp_password,
                                     resource => 'sms-server');
        if (@xmpp_auth) {
          if ($xmpp_auth[0] ne 'ok') {
            print "Incorrect XMPP authentication: $xmpp_auth[1]\n";
            $xmpp->Disconnect();
            delete($xmpp->{PROCESSERROR});
          } else {          
            $xmpp->PresenceSend(show => 'available');
          }
        } else {
          $xmpp->Disconnect();
          delete($xmpp->{PROCESSERROR});
          print STDERR "Failed to authenticate on XMPP server: $!\n";
        }
      } else {
        print STDERR "Failed to connect to XMPP server: $!\n";
      }
    }
  }
  $waittime = tv_interval($timers{'pop'}, [gettimeofday]);
  if ($use_pop3 && $pop3 && $waittime > $pop3_interval) {
    if (!$pop3->Alive()) {
      $pop3->Connect() or print STDERR 'POP3 Error: ' . $pop3->Message();
    }
    if ($pop3->Alive()) {
      my %recv_mail = (count => $pop3->Count());
      print "You have $recv_mail{count} new e-mails\n" if $recv_mail{count};
      for ($recv_mail{num} = 1; $recv_mail{num} <= $recv_mail{count}; $recv_mail{num}++) {
        delete @recv_mail{qw(from to subject message_length message_text)};
        @{$recv_mail{header}} = $pop3->Head($recv_mail{num});
        $recv_mail{body} = $pop3->Body($recv_mail{num});
        $recv_mail{full} = $pop3->HeadAndBody($recv_mail{num});
        if (length $pop3_file) {
          my %content_mail = ('header' => $recv_mail{header}, 'body' => $recv_mail{body});
          my $content_file = get_unused_file $pop3_file;
          store(\%content_mail, $content_file) or print STDERR "Error serializing mail to file: $content_file\n";
          undef %content_mail;
          undef $content_file;
        }
        foreach (@{$recv_mail{header}}) {
          if ($_ =~ /^([^:]+): (.+)/) {
            switch (lc($1)) {
              case 'from'           { $recv_mail{from}      = $2 }
              case 'to'             { $recv_mail{to}        = $2 }
              case 'subject'        { $recv_mail{subject}   = $2 }
            }
          }
        }
        $recv_mail{from} = $2 if $recv_mail{from} =~ /(?|"([^"]+)"|([^<]+))?\s*<([^>]+)>/;
        $recv_mail{to} = $2 if $recv_mail{to} =~ /(?|"([^"]+)"|([^<]+))?\s*<([^>]+)>/;
        chomp $recv_mail{subject};
        if ($recv_mail{to} eq $mail_local_address && $recv_mail{subject} =~ /^\+?[0-9]+$/) {
          ($recv_mail{message_length}, $recv_mail{message_text}) = get_text_from_multitype $recv_mail{full};
          for (@mail_remote_list) {
            next if $_->{'mailaddr'} ne $recv_mail{from};
            mailqueue_add \@authentication_list, $_->{'id'}, \%recv_mail;
            print "[$recv_mail{from}] QUEUE SMS(${recv_mail{subject}}): ${recv_mail{message_text}}\n";
          }
        }
        $pop3->Delete($recv_mail{num});
      }
      $timers{'pop'} = [gettimeofday];
      $pop3->Close() && undef $pop3->{SOCKET};
    } else {
      $pop3->Close() && undef $pop3->{SOCKET};
    }
  }
  for (@authentication_list) {
    next if !defined $_->{'peer'};
    if (defined $_->{'sendmsg'} && defined $_->{'sendmsg'}{'phonewait'}) {
      $waittime = tv_interval($_->{'sendmsg'}{'phonewait'}, [gettimeofday]);
      if ($waittime > 3 &&
          defined $_->{'sendmsg'}{'phonemsg'} && $_->{'sendmsg'}{'phase'} eq 'SubmitNumberRequest') {
        $_->{'sendmsg'}{'phonewait'} = undef;
        $sockdata = "SEND $_->{sendmsg}{sendid} $_->{sendmsg}{phonemsg}[0] $_->{sendmsg}{phonemsg}[1]\n";
        send($serversocket, $sockdata, 0, $_->{'peer'});
        print "SOCKET $sockpeer{host}:$sockpeer{port} >> $sockdata\n" if $socket_debug;
      }
    }
    next if defined $_->{'sendmsg'} || !scalar(@{$_->{'sendqueue'}});
    my $recv_mail = shift @{$_->{'sendqueue'}};
    $_->{'sendmsg'} = {'phase' => 'BulkSMSRequest', 'sendid' => $server_uuid++,
                       'phonemsg' => undef, 'phonequeue' => [],
                       'phoneuuid' => 1, 'phonewait' => undef};
    # TODO implements phone list
    push @{$_->{'sendmsg'}{'phonequeue'}}, $recv_mail->{subject};
    # TODO implements MSG re-send on timeout
    $sockpeer{'addr'} = (sockaddr_in($_->{'peer'}))[1];
    $sockpeer{'host'} = inet_ntoa($sockpeer{'addr'});
    $sockpeer{'port'} = (sockaddr_in($_->{'peer'}))[0];
    $sockdata = "MSG $_->{sendmsg}{sendid} $recv_mail->{message_length} $recv_mail->{message_text}\n";
    send($serversocket, $sockdata, 0, $_->{'peer'});
    print "SOCKET $sockpeer{host}:$sockpeer{port} >> $sockdata\n" if $socket_debug;
  }
}

__END__

=head1 NAME

sms-server.pl - A Perl script to act as GSM server of a GSM IP gateway

=head1 SYNOPSIS

sms-server.pl [options]

  Options:
    --help                  Show this help screen
    --man                   Show manual pages

    --daemon                Run this process as daemon

    --log-out=<FILE>        Set a file to write output log
    --log-err=<FILE>        Set a file to write error log
    --pid-file=<FILE>       Set a file to write PID information

    --server-host=<HOST>    Set host where to listening for packets
    --server-port=<PORT>    Set a UDP listening port
    --add-authentication=<AUTH>
                            Add a server ID and password for authetication
    --socket-debug          Enable debug information of socket traffic

    --config-file=<FILE>    Set a configure file to use

    --use-mysql             Store SMS messages into MySQL database
    --mysql-database=<DB>   MySQL table name
    --mysql-sock=<SKT>      MySQL socket connection

    --use-csv               Store SMS messages into CSV file
    --csv-dir=<DIR>         Indicate directory to save CSV file
    --csv-file=<FILE>       Indicate CSV file to store SMS messages

    --use-xmpp              Indicate to send/receive SMS using a XMPP server
    --xmpp-debug            Print debug information of XMPP data
    --xmpp-host=<HOST>      Indicate XMPP server to connect
    --xmpp-user=<USR>       Local JID to connect on XMPP server
    --xmpp-password=<PWD>   Indicate XMPP password for local JID
    --jid-remote=<RJID>     Indicate remote JID mapping

    --use-smtp              Indicate to send SMS messages throw e-mail
    --smtp-host=<HOST>      Indicate hostname/ipaddress for SMTP connection
    --smtp-domain=<DOM>     Indicate domain to use in SMTP server       
    --smtp-auth=<AUTH>      SMTP autentication type
    --smtp-username=<USR>   SMTP user authetication
    --smtp-password=<PWD>   SMTP password authetication
    --verify-pop            Indicate to get POP3 messages and send in SMS
    --pop-host=<HOST>       Indicate hostname/ipaddress for POP3 connection
    --pop-username=<USR>    POP3 user authetication
    --pop-password=<PWD>    POP3 password authentication
    --pop-storage=<FILE>    Store incoming POP3 messages
    --pop-interval=<INT>    Set interval between POP3 mail checking
    --mail-addr-local=<LA>  Indicate my local e-mail address
    --mail-addr-remote=<RM> Indicate remote e-mail address

=head1 OPTIONS

=over 8

=item B<--help>

Print a brief program help message end exits

=item B<--man>

Show this manual page

=item B<--daemon>

Send this process to background (run as daemon)

=item B<--log-out>=I<FILE>

Set a file to redirect standard output to. On a daemon process if wasn't
specified standard output will be redirected to /dev/null

=item B<--out-err>=I<FILE>

Same as B<--out-out>, but this refer to error output

=item B<--pid-file>=I<FILE>

Set a file to write the current PID, usefull for daemon process

=item B<--server-host>=I<HOST>

Set IP address or hostname to listening for packages from GSM gateway

=item B<--server-port>=I<PORT>

Set a listening UDP port to receive packages from GSM gateway

=item B<--add-authentication>=I<AUTH>

Add new authentication pair of ID and password to this GSM server.
Pair of I<AUTH> must be in separated a colon, for example:
I<ID>B<:>I<Password>

This option can be used several times to add how many authetication pair
as you wish

=item B<--socket-debug>

This option will send to standard out or log file informations about data, IP
and port of received from or send to peer 

=item B<--config-file>=I<FILE>

Read script configurations from I<FILE>

B<Note:> Paramaters settings will always overide config file settings

=item B<--use-mysql>

Indicate the program to store retrieve messages into MySQL database

=item B<--mysql-database>=I<DB>

If store messages in MySQL use table indicate by I<DB>

=item B<--mysql-sock>=I<SKT>

Indicate the socket used to connect to MySQL database

=item B<--use-csv>

Indicate the program to store retrieve messages into CSV file

=item B<--csv-dir>=I<DIR>

Indicate diretory to save/open CSV file

=item B<--csv-file>=I<FILE>

If store messages in CSV format, use file indicate by I<FILE>

=item B<--use-xmpp>

If set enable Jabber/XMPP interface to send SMS messages

=item B<--xmpp-debug>

If set print out XMPP debug information

=item B<--xmpp-host>=I<HOST>

Set Jabber/XMPP host to connect

=item B<--xmpp-user>=I<USR>

Set Jabber/XMPP JID to autheticate

=item B<--xmpp-password>=I<PWD>

Set Jabber/XMPP password for authenticate local JID

=item B<--jid-remote>=I<REMOTE-JID>

Remote JID address that can send and receive SMS messages
I<REMOTE-JID> must be in format:
I<ID>B<:>I<JID-ADDRESS>
Where I<ID> is authentication ID of GSM Server and I<JID-ADDRESS> is the
Jabber-ID address where all messages came from specified I<ID> will be sent

=item B<--use-smtp>

If set send all SMS messages to e-mail throw SMTP

=item B<--smtp-host>=I<HOST>

Set SMTP hostname/ipaddress

=item B<--smtp-domain>=I<DOMAIN>

Set SMTP domain to use in reply of "HELO" message

=item B<--smtp-auth>=I<AUTH>
       
Select some SMTP autentication type

Suported types:

=over 4

=item *

CRAM_MD5

=item *

DIGEST_MD5

=item *

LOGIN

=item *

PLAIN

=back

=item B<--smtp-username>=I<USER>

Set username to authenticate SMTP session

=item B<--smtp-password>=I<PASS>

Set user password to authenticate SMTP session

=item B<--verify-pop>

Check POP3 account for incoming e-mails.

All incoming e-mails received from address indicate by B<--mail-addr-remote>
will be send thru SMS message to phone number indicated in subject field.

Messages must be in plain text format and must not exceed 140 characters

=item B<--pop-host>=I<HOST>

Set POP3 hostname/ipaddress

=item B<--pop-username>=I<USR>

Set username to autheticate POP3 session

=item B<--pop-password>=I<PWD>

Set user password to authenticate POP3 session

=item B<--pop-storage>=I<FILE>

Set a file to store income POP3 messages

=item B<--pop-interval>=I<INT>

Server will check for new mail messages in POP3 within interval
of I<INT> seconds

=item B<--mail-addr-local>=I<LOCAL-ADDR>

Your local e-mail address used to send e-mails

=item B<--mail-addr-remote>=I<REMOTE-ADDR>

Recipient e-mail address to send e-mails
I<REMOTE-ADDR> must be in format:
I<ID>B<:>I<EMAIL-ADDRESS>
Where I<ID> is authentication ID of GSM Server and I<EMAIL-ADDRESS> is the
e-mail address where all messages came from specified I<ID> will be sent

=back

=head1 DESCRIPTION

B<sms-server.pl> is a SMS server aplication, it can be used to send or receive
SMS messages to/from an IP SMS Gateway, this application provides a way to
move theses messages to a persistent storage or send them thru e-mail

If you configure a POP3 account you can receive messages and send them
thru SMS using your GSM gateway

=head1 SQL TABLE

This section describe the format of SQL structure to store your SMS messages

=head2 MYSQL

CREATE TABLE recv_sms (
    authid VARCHAR(32),
    cid_number VARCHAR(16) NOT NULL,
    cid_name VARCHAR(64),
    msg_date DATETIME NOT NULL,
    tz INTEGER,
    message VARCHAR(160),
    INDEX (cid_number, cid_name, msg_date),
    INDEX (cid_name, cid_number, msg_date),
    INDEX (msg_date DESC)
E<10>);

CREATE TABLE send_sms (
    destination VARCHAR(32) NOT NULL,
    msg_date DATETIME NOT NULL,
    message VARCHAR(160),
    INDEX (destination, msg_date),
    INDEX (msg_date DESC)
E<10>);

=cut

