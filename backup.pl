#!/usr/bin/perl -w
# backup.pl - Makes tar backups of local or remote filesystems
# $Id$

use strict;
use Sys::Syslog qw(:DEFAULT setlogsock);
use Getopt::Long;
use Pod::Usage;
use POSIX qw(strftime);
use File::Temp qw(tempfile);

# function prototypes
sub LogMessage;
sub LogDebug;
sub LogInfo;
sub LogWarning;
sub LogError;
sub LogFatalAndExit;
sub InitializeLogging();
sub ReadConfigFile($);
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

sub CheckMandatoryOptions() {
  my $key;
  foreach $key (@mandatory_opts) {
    if( !defined($opt{$key}) ) {
      LogFatalAndExit("mandatory option <$key> not defined");
    }
  }
}

sub ProcessCommandLine() {
  my ($help, $man);

  my $result = GetOptions('config=s' => \$opt{ConfigFile},
                          'level=i' => \$opt{LevelFromCmdline},
                          'fs=s' => \@filesystems,
                          'help' => \$help,
                          'man' => \$man);

  if( $help ) {
    pod2usage(-verbose => 0, -exitval => 0);
  }
  if( $man ) {
    pod2usage(-verbose => 2, -exitval => 1);
  }
  if( !$result ) {
    pod2usage(-verbose => 0, -exitval => 1);
  }

  # in case some 'fs' args were comma-separated lists
  @filesystems = split(/,/, join(',', @filesystems));
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

__END__

=head1 NAME

backup - backs up local and/or remote data to disk

=head1 SYNOPSIS

backup [options]

 Options:
   --config <f>		read configuration from <f>
   --all		backup all filesystems in configuration file
   --level <l>		perform a level <l> backup
   --fs <f>		a directory to back up, or host:directory
   --help		print a usage summary
   --man		read the full man page

=head1 DESCRIPTION

The B<backup> program uses GNU B<tar>, B<bzip2>, and B<ssh> to back up
local and remote directory structures to disk. Any number of levels of
backups are supported, with level I<0> being a full backup and
level I<n> (where I<n> > 0) being an incremental backup of all the changes
since the last level I<n-1> backup.

Old backups are not automatically deleted, so you must manage backup retention
separately by deleting old backup files.

=head1 OPTIONS

The following options may be specified on the command line. Some of these
options may also be specified in the configuration file. When an option is
specified in both places, the value from the command line is used. The
configuration file is described in the L<"CONFIGURATION FILE"> section.

=over

=item B<--config I<f>>

Read configuration from file I<f>. If not specified, configuration is read
from F</etc/backup/backup.conf>. The configuration file is described
in the L<"CONFIGURATION FILE"> section.

=item B<--all>

Back up all filesystems listed in the configuration file. If this option is
given, no filesystems need to be explicitly listed on the command line with
the C<--fs> option, and all filesystems listed with the C<Filesystems>
option in the configuration file will be backed up.

=item B<--level I<l>>

Specifies that a level I<l> backup will be performed on the filesystems. The
level may be any integer >= 0.

The corresponding configuration file option is C<Level>.

=item B<--fs I<f>>

Specifies one or more filesystems to back up. Each filesystem may by either
a local directory, or a remote directory of the form I<host:directory>. To
back up multiple filesystems, the C<--fs> option may be given multiple times,
or multiple filesystems may be given as one argument in a comma-separated
list. For example, the following are all valid ways to specify that three
filesystems should be backed up:

	--fs / --fs host1:/var --fs host2:/etc
	--fs /,host1:/var,host2:/etc
	--fs / --fs host1:/var,host2:/etc

=item B<--help>

Print a usage summary and exit.

=item B<--man >

Read the full man page for this program.

=back

=head1 CONFIGURATION FILE

Options are specified in the configuration in lines that look like:

=over

I<option>=I<value>

=back

You may add any amount of whitespace on either side of the C<=>, so the
following will also work:

=over

I<option> = I<value>

=back

The following options may be specified in the configuration file:

=over

=item B<Filesystems>

Specifies the filesystems to back up. Each filesystem may be either a local
directory or a remote directory of the form I<host:directory>. To specify
multiple directories, use a comma-separated list.

=item B<Level>

Specifies that a level I<l> backup will be performed on the filesystems. The
level may be any integer >= 0.

=item B<BackupDirectory>

The directory to which the completed backups will be written.

=item B<StateDirectory>

The directory in which to keep data about when the last backup was performed
for each filesystem.

=item B<SyslogFacility>

Logging is done via syslog. The option specifies the syslog facility to use
when logging.

=item B<SshIdentityFile>

The SSH identity to use when running commands on remote systems. This identity
should not have a passphrase. A good way to test that the identity will work is
to run:

=over

ssh -i I<IdentityFile> -o Batchmode=yes root@I<host>

=back

=item B<ExcludeFile>

A file listing pathnames to exclude from backups. The pathnames are relative
to the directory being backed up. For example, to exclude the C</tmp>
directory when backing up C</>, specify a pathname of C<tmp> in the exclude
file.

This file must also exist on remote systems in this location.

=back

=cut
