#!/usr/bin/perl -w
# backup.pl - Makes tar backups of local or remote filesystems
# $Id$

use strict;
use Sys::Syslog qw(:DEFAULT setlogsock);
use Getopt::Long;
use POSIX qw(strftime);
use File::Temp qw(tempfile);

# function prototypes
sub PrintUsage();
sub LogMessage;
sub LogDebug;
sub LogInfo;
sub LogWarning;
sub LogError;
sub LogFatalAndExit;
sub InitializeLogging();
sub ReadConfigFile($);
sub PrintUsageAndExit();
sub CheckMandatoryOptions();
sub ProcessCommandLine();
sub Filename($);
sub GetLastBackupTime($$);
sub UpdateLastBackupTime($$$);
sub CurrentTimeAsTimestamp();
sub BackupFilesystem($$);
sub RunIt($);

# get the basename of this program
my $basename = $0; $basename =~ s:^.*/::;

# some defaults for options in the config file
my %opt;
$opt{'ConfigFile'} = '/etc/backup/backup.conf';
$opt{'SshIdentityFile'} = '/etc/backup/identity';
$opt{'ExcludeFile'} = '/etc/backup/exclude';
$opt{'SyslogFacility'} = 'user';
$opt{'StateDirectory'} = '/var/run/backup';
$opt{'DestinationDirectory'} = '/backup';

# options which must be specified
my @mandatory_opts = qw(BackupDirectory Filesystems Level);

# filesystems to back up
my @filesystems = ();

# is logging initialized yet?
my $logging_initialized = 0;

# run this at exit
END {
  if( $logging_initialized ) {
    closelog();
  }
}

sub PrintUsage() {
  print << "__EOF__";
USAGE: $0 [ --config <cfgfile> ] [ --all ] <filesystem> [ <filesystem> .. ]
__EOF__
}

sub LogMessage {
  my $priority = $_[0]; shift;
  my $format = $_[0]; shift;
  my @args = @_;

  if( $logging_initialized ) {
    syslog($priority, $format, @args);
  } else {
    $format = "[$priority] $format";
    if( $format !~ /\n$/ ) {
      $format .= "\n";
    }
    printf $format, @args;
  }
}

sub LogDebug {
  LogMessage('debug', @_);
}

sub LogInfo {
  LogMessage('info', @_);
}

sub LogWarning {
  LogMessage('warning', @_);
}

sub LogError {
  LogMessage('err', @_);
}

sub LogFatalAndExit {
  LogMessage('err', @_);
  exit(1);
}

sub InitializeLogging() {
  setlogsock('unix');
  openlog($basename, 'pid', $opt{'SyslogFacility'});
  $logging_initialized = 1;
}

sub ReadConfigFile($) {
  my $configfile = $_[0];

  if( !defined(open(CONFIG, $configfile)) ) {
    LogFatalAndExit("Can't open config file $configfile: $!");
  }

  while( <CONFIG> ) {
    chomp;		# remove trailing newline
    next if /^\s*$/;	# skip blank lines
    next if /^#/;	# skip comments

    # process lines that look like "name=value"
    if( /^\s*(\S+)\s*=\s*(.+)\s*$/ ) {
      $opt{$1} = $2;
    }
  }

  # override with some options from command line
  if( defined($opt{LevelFromCmdline}) ) {
    $opt{Level} = $opt{LevelFromCmdline};
  }

  close CONFIG;
}

sub PrintUsageAndExit() {
  print << "__EOF__";
USAGE: backup.pl [options]
__EOF__
  exit 2;
}

sub CheckMandatoryOptions() {
  my $key;
  foreach $key (@mandatory_opts) {
    if( !defined($opt{$key}) ) {
      LogFatalAndExit("mandatory option <$key> not defined");
    }
  }
}

sub ProcessCommandLine() {
  my $result = GetOptions('config=s' => \$opt{ConfigFile},
                          'level=i' => \$opt{LevelFromCmdline},
                          'fs=s' => \@filesystems);

  # in case some 'fs' args were comma-separated lists
  @filesystems = split(/,/, join(',', @filesystems));

  if( !$result ) {
    PrintUsageAndExit();
  }
}

# SUBROUTINE:  Filename($filesystem)
# DESCRIPTION: Returns a filename corresponding to $filesystem
sub Filename($) {
  my $filesystem = $_[0];

  # split into host and filesystem parts
  my ($host, $fs);
  if( $filesystem =~ /:/ ) {
    ($host, $fs) = split /:/, $filesystem, 2;
  } else {
    $host = '';
    $fs = $filesystem;
  }

  # eliminate leading slashes in $fs
  $fs =~ s:^/::;
  # turn other slashes into dashes;
  $fs =~ s:/:-:g;
  # special case for '/' -- make it 'root'
  if( $fs eq '' ) {
    $fs = 'root';
  }

  if( $host ne '' ) {
    return "$host-$fs";
  } else {
    return $fs;
  }
}

# SUBROUTINE:  GetLastBackupTime($filesystem, $level)
# RETURNS:     Time of last backup, as string suitable for tar -N
sub GetLastBackupTime($$) {
  my ($filesystem, $level) = @_;

  # calculate name of timestamp file
  my $tstampfile = $opt{StateDirectory} . '/' . Filename($filesystem) 
                   . ".$level";

  if( !defined(open TSTAMP, "<$tstampfile") ) {
    # assume this filesystem has never been backed up
    return undef;
  }
  # read the first line of the file as the (time_t) time of last backup
  my $time = <TSTAMP>;
  close TSTAMP;
  chomp $time;
  if( $time ne '' ) {
    return $time;
  } else {
    return undef;
  }
}

# SUBROUTINE:  UpdateLastBackupTime($filesystem, $level, $time_t)
# DESCRIPTION: Sets the last backup time for $filesystem,$level to the time
#              specified by $time_t
sub UpdateLastBackupTime($$$) {
  my ($filesystem, $level, $time_t) = @_;

  # calculate name of timestamp file
  my $tstampfile = $opt{StateDirectory} . '/' . Filename($filesystem)
                   . ".$level";
                                                                                
  if( !defined(open TSTAMP, ">$tstampfile") ) {
    LogError("can't write to $tstampfile: $!");
    return;
  }
  # write the current time to the file
  my ($sec, $min, $hour, $mday, $mon, $year) = localtime($time_t);
  my $time = strftime("%m/%d/%Y %H:%M:%S", $sec, $min, $hour, $mday, $mon, $year);
  print TSTAMP "$time\n";
  close TSTAMP;
}

# SUBROUTINE:  CurrentTimeAsTimestamp()
sub CurrentTimeAsTimestamp() {
  my ($sec, $min, $hour, $mday, $mon, $year) = localtime( time() );
  return strftime("%Y%m%d%H%M%S", $sec, $min, $hour, $mday, $mon, $year);
}

# SUBROUTINE:  PingHost($host)
# DESCRIPTION: Checks to see if $host is up
# RETURNS:     1 if $host is up, 0 otherwise
sub PingHost($) {
  my $host = $_[0];

  my $rc = system('ssh -o BatchMode=yes -i ' . $opt{SshIdentityFile}
                  . " $host uptime > /dev/null 2>&1") / 256;

  if( $rc == 0 ) {
    return 1;
  } else {
    return 0;
  }
}

# SUBROUTINE:  BackupFilesystem($filesystem, $level)
sub BackupFilesystem($$) {
  my ($filesystem, $level) = @_;

  LogInfo("starting level $level backup of $filesystem");
  # save the start time
  my $backupStartTime = time();

  # break up $filesystem into host/directory parts
  my ($host, $dir);
  if( $filesystem =~ /:/ ) {
    ($host, $dir) = split /:/, $filesystem, 2;
  } else {
    $dir = $filesystem;
  }

  # if remote backup, make sure host is up
  if( defined($host) && !PingHost($host) ) {
    LogError("$host is down, skipping level $level backup of $filesystem");
    # last backup time is not updated
    return 0;
  }

  # calculate the reference time for changed files
  # leave as undef for full backup
  my $reftime;
  if( $level > 0 ) {
    $reftime = GetLastBackupTime($filesystem, $level-1);
  }
  if( !defined($reftime) ) {
    LogInfo("backing up all files");
  } else {
    LogInfo("backing up files changed since: $reftime");
  }

  # build the tar command
  # output must go to stdout, since this tar might not run on the system
  # where the backups are written
  my $tarcmd = 'tar ';
  if( defined($reftime) ) {
    $tarcmd .= "-N '$reftime' ";
  }
  $tarcmd .= '--one-file-system -jcf - --exclude-from=' .
             $opt{ExcludeFile} . " $dir";

  # wrap the tar in an ssh if this is a remote backup
  my $command;
  if( defined($host) ) {
    $command = 'ssh -o BatchMode=yes -i ' . $opt{SshIdentityFile} .
               " $host \"PATH=/usr/local/bin:\$PATH; export PATH; $tarcmd\"";
  } else {
    # local backup
    $command = $tarcmd;
  }
  # make the output go to the backup file
  $command .= ' > ' . $opt{BackupDirectory} . '/' . Filename($filesystem) .
              ".$level." . CurrentTimeAsTimestamp() .
              '.tar.bz2';

  # run the backup command
  LogDebug("running: $command");

  if( RunIt($command) ) {
    LogInfo("completed level $level backup of $filesystem");
    UpdateLastBackupTime($filesystem, $level, $backupStartTime);
    return 1;
  } else {
    LogError("errors during level $level backup of $filesystem");
    UpdateLastBackupTime($filesystem, $level, $backupStartTime);
    return 0;
  }
}

# SUBROUTINE:  RunTar($cmdline)
# DESCRIPTION: Runs a command line and scrapes stderr for "real"
#              errors from tar.
# RETURNS:     1=success, 0=failure
sub RunIt($) {
  my $command = $_[0];
  my ($stderrfh, $stderrfile) = tempfile('backup.stderr.XXXXXX', DIR => File::Spec->tmpdir(), UNLINK => 1);
  close $stderrfh;

  # tar stderr lines that are okay to ignore (won't be reported)
  my @ok_to_ignore = ( '^tar:.*: door ignored$',
                       '^tar:.*: socket ignored$',
                       '^tar: Removing leading',
                       '^tar: Error exit delayed' );

  # run the command
  my $rc = system("$command 2>$stderrfile") / 256;
  my $errors = 0;
  my ($re, $real_error);
  open STDERRFILE, $stderrfile;
  while(<STDERRFILE>) {
    $real_error = 1;
    foreach $re ( @ok_to_ignore ) {
      if( $_ =~ $re ) {
        $real_error = 0;
      }
    }
    if( $real_error == 1 ) {
      LogError("stderr: $_");
      $errors = 1;
    }
  }
  close STDERRFILE;

  if( $errors ) {
    return 0;
  } else {
    return 1;
  }
}


# main()
ProcessCommandLine();
ReadConfigFile($opt{ConfigFile});
CheckMandatoryOptions();
InitializeLogging();

# make a list of filesystems to back up
if( $#filesystems < 0 ) {
  # not given on command line, take from config file
  @filesystems = split(/[,\s]+/, $opt{Filesystems});
}

# back up each filesystem
my $failures = 0;
foreach $_ (@filesystems) {
  if( !BackupFilesystem($_, $opt{Level}) ) {
    $failures = 1;
  }
}

if( $failures ) {
  exit 1;
} else {
  exit 0;
}
