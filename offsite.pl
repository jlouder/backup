#!/usr/bin/perl -w
# $Id$
# offsite.pl - Makes DVD images of the most recent backups of each fs

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
sub ProcessCommandLine();
sub CheckMandatoryOptions();
sub ReadConfigFile($);
sub GetBackupFiles($);
sub CheckWorkDirectory($);
sub NumParts($$$);
sub Basename($);
sub EncryptFile($$$$$);
sub MakeFilesForImages;

# get the basename of this program
my $basename = $0; $basename =~ s:^.*/::;

# some default options
my %opt;
$opt{'UseSyslog'} = 0;
$opt{'SyslogFacility'} = 'user';
$opt{'BlockSize'} = 4096;
$opt{'MaxFileSize'} = 2000000000;
$opt{'MaxImageSize'} = 4698112000;
my %cmdline;
$cmdline{'ConfigFile'} = '/etc/backup/backup.conf';

# options with no defaults which must be specified
my @mandatory_opts = qw(BackupDirectory WorkDirectory PasswordFile);

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

  if( $logging_initialized && $opt{'UseSyslog'} ) {
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

sub ProcessCommandLine() {
  my ($help, $man);

  my $result = GetOptions('syslog!' => \$cmdline{'UseSyslog'},
                          'facility=s' => \$cmdline{'SyslogFacility'},
                          'backupdir=s' => \$cmdline{'BackupDirectory'},
                          'workdir=s' => \$cmdline{'WorkDirectory'},
                          'config=s' => \$cmdline{'ConfigFile'},
                          'dryrun' => \$cmdline{'DryRun'},
                          'blocksize=s' => \$cmdline{'BlockSize'},
                          'maxfilesize=s' => \$cmdline{'MaxFileSize'},
                          'maximagesize=s' => \$cmdline{'MaxImageSize'},
                          'pwfile=s' => \$cmdline{'PasswordFile'},
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
}

# SUBROUTINE:  CheckMandatoryOptions()
# DESCRIPTION: Logs an error and exits if any option in @mandatory_opts is not
#              set.
sub CheckMandatoryOptions() {
  my $key;
  foreach $key (@mandatory_opts) {
    if( !defined($opt{$key}) ) {
      LogFatalAndExit("mandatory option <$key> not defined");
    }
  }
}

# SUBROUTINE:  ReadConfigFile($cfgfile)
# DESCRIPTION: Reads configuration from $cfgfile into %opt, and copies any
#              command line options into %opt so that they take priority.
sub ReadConfigFile($) {
  my $configfile = $_[0];

  if( !defined(open(CONFIG, $configfile)) ) {
    LogFatalAndExit("Can't open config file $configfile: $!");
  }

  while( <CONFIG> ) {
    chomp;              # remove trailing newline
    next if /^\s*$/;    # skip blank lines
    next if /^#/;       # skip comments

    # process lines that look like "name=value"
    if( /^\s*(\S+)\s*=\s*(.+)\s*$/ ) {
      $opt{$1} = $2;
    }
  }

  close CONFIG;

  # everything specified on command line overrides config file
  # unspecified options have keys, so make sure values are defined
  foreach my $key ( keys %cmdline ) {
    if( defined($cmdline{$key}) ) {
      $opt{$key} = $cmdline{$key};
    }
  }
}

# SUBROUTINE:  GetBackupFiles($backup_dir)
# DESCRIPTION: Picks files to be included in this offsite backup set.
# ARGUMENTS:   $backup_dir is the directory containing backup files
# RETURNS:     The list of files to include in the backup
sub GetBackupFiles($) {
  my $backup_dir = $_[0];

  # get a list of filesystems
  my @filesystems = split /\n/, `ls ${backup_dir}/*.bz2 | xargs -n 1 basename \\
                     | cut -d. -f1 | sort -u`;

  # for each filesystem, get latest level 0 and latest level 1 (if more
  # recent than level 0)
  my @files;
  my $fs;
  foreach $fs ( @filesystems ) {
    # most recent level 0 must exist
    my $level0 = `ls ${backup_dir}/${fs}.0.* | tail -1`;
    chomp $level0;
    if( $level0 =~ /^$/ ) {
      LogError("no level 0 backup found for $fs");
    } else {
      push @files, $level0;
    }

    # if there's a level 1 more recent than the level 0, get that too
    my $level1 = `find $backup_dir -name "${fs}.1.*" -newer $level0 | tail -1`;
    chomp $level1;
    if( $level1 !~ /^$/ ) {
      push @files, $level1;
    }
  }

  return @files;
}

# SUBROUTINE:  CheckWorkDirectory($work_dir)
# DESCRIPTION: Makes sure $work_dir exists and is writeable. Creates it if
#              necessary.
# RETURNS:     1 if $work_dir exists and is writeable, 0 otherwise
sub CheckWorkDirectory($) {
  my $work_dir = $_[0];

  # create $work_dir if it doesn't exist
  if( ! -e $work_dir ) {
    if( !mkdir($work_dir) ) {
      LogError("can't create work directory $work_dir: $!");
      return 0;
    } else {
      return 1;
    }
  } elsif( ! -w $work_dir ) {
    LogError("work directory $work_dir is not writeable");
    return 0;
  }

  return 1;
}

# SUBROUTINE:  NumParts($file, $image_bytes, $remaining_bytes)
# DESCRIPTION: Determines the number of parts that $file must be split into
#              assuming $remaining_bytes left for this image and $image_bytes
#              available on each image.
# RETURNS:     The number of parts, or zero on error.
sub NumParts($$$) {
  my ($file, $image_bytes, $remaining_bytes) = @_;

  # get the file's size
  my $filesize = (stat $file)[7];
  if( !defined($filesize) ) {
    LogError("can't stat $file");
    return 0;
  }

  my $parts = 0;
  while( $filesize > 0 ) {
    if( $remaining_bytes > $opt{'MaxFileSize'} ) {
      $filesize -= $opt{'MaxFileSize'};
      $remaining_bytes -= $opt{'MaxFileSize'};
    } else {
      $filesize -= $remaining_bytes;
      $remaining_bytes = 0;
    }
    $parts++;

    if( $remaining_bytes <= 0 ) {
      $remaining_bytes = $image_bytes;	# start a new image
    }
  }

  return $parts;
}

# SUBROUTINE:  Basename($pathname)
# DESCRIPTION: Returns the basename of $pathname
sub Basename($) {
  my $pathname = $_[0];

  $pathname =~ s:^.*/::;

  return $pathname;
}

# SUBROUTINE:  EncryptFile($sourcefile, $destfile,
#                          $offsetblocks, $copybytes, $pwfile)
# DESCRIPTION: Encrypts a portion of $sourcefile that is $copyblocks blocks
#              in length, starting at $offsetblocks blocks into the file.
#              If $copyblocks is 0, the file is encrypted until EOF.
#              The output is named
#              $destfile. Uses the contents of $pwfile as the passphrase.
sub EncryptFile($$$$$) {
  my ($sourcefile, $destfile, $offsetblocks, $copyblocks, $pwfile) = @_;

  # on a dry run, don't do anything
  if( defined($opt{'DryRun'}) ) {
    return;
  }

  my $cmdline = "dd if=$sourcefile bs=$opt{'BlockSize'} ";
  if( $offsetblocks > 0 ) {
    $cmdline .= "skip=$offsetblocks ";
  }
  if( $copyblocks > 0 ) {
    $cmdline .= "count=$copyblocks ";
  }
  $cmdline .= "| gpg -c --passphrase-fd 3 --output $destfile -z 0 3<$pwfile";

  LogDebug("running: $cmdline");
  my $rc = system($cmdline) / 256;
  if( $rc != 0 ) {
    LogError("encrypt of $sourcefile ($copyblocks blocks @ offset " .
             "$offsetblocks blocks) failed: returned $rc");
  }
}

# SUBROUTINE:  MakeFilesForImages($image_size, $work_dir, @files)
# DESCRIPTION: Makes directories in $work_dir with files to be made into ISO
#              images.
# ARGUMENTS:   $image_size is the maximum # bytes to put in one image
#              $work_dir is where the images should be made
#              @files are the files to encrypt and split into images
# RETURNS:     The number of directories created in $work_dir
sub MakeFilesForImages {
  my $image_size = shift @_;
  my $work_dir = shift @_;

  my $file;
  my $image_num = 0;
  my $remaining = 0;

  mkdir "${work_dir}/1"
    || LogFatalAndExit("Can't create work directory ${work_dir}/1: $!");

  # for each file ...
  while( $file = shift @_ ) {
    my $parts = NumParts("$file", $image_size,
                         $remaining == 0 ? $image_size : $remaining);
    my $count = 1;
    my $offsetblocks = 0;
    my $filesize = (stat "$file")[7];
    my $destname;
    my $copyblocks;

    # for each part ... (some files may only have 1 part)
    while( $count <= $parts ) {
      # roll over to next image if no bytes remain for this image
      if( $remaining < $opt{'BlockSize'} ) {
        $image_num++;
        LogDebug "--- starting image $image_num";
        $remaining = $image_size;

        # make the next work directory
        mkdir "${work_dir}/${image_num}"
          || LogFatalAndExit("Can't create work directory " .
                             "${work_dir}/${image_num}: $!");
      }

      # calculate how much of the file this part is, and how much
      # image space remains
      if( $filesize >= (($remaining < $opt{'MaxFileSize'}) ? $remaining : $opt{'MaxFileSize'}) ) {
        # fills up this image
        $copyblocks = int($remaining / $opt{'BlockSize'});
        if( $copyblocks > int($opt{'MaxFileSize'} / $opt{'BlockSize'}) ) {
          $copyblocks = int($opt{'MaxFileSize'} / $opt{'BlockSize'});
        }
        $filesize -= $copyblocks * $opt{'BlockSize'};
        $remaining -= $copyblocks * $opt{'BlockSize'};
      } else {
        # fits on this image with room to spare
        $remaining -= $filesize;
        $copyblocks = 0; # 0=copy to EOF
      }

      # determine the name of the file as it will appear in the image
      # use a '.##of##' suffix if it's a split file
      if( $parts > 1 ) {
        $destname = sprintf "%s/%d/%s.%02dof%02d.gpg", $work_dir, $image_num,
                            Basename($file), $count, $parts;
      } else {
        $destname = sprintf "%s/%d/%s.gpg", $work_dir, $image_num,
                            Basename($file);
      }
      LogDebug("$destname: $copyblocks @ $offsetblocks");
      EncryptFile($file, $destname, $offsetblocks, $copyblocks,
                  $opt{'PasswordFile'});

      # calculate offset for next part
      $offsetblocks += $copyblocks;

      # move on to the next part
      $count++;
    }
  }

  # return the number of directories created
  return $image_num;
}


# main()
ProcessCommandLine();
ReadConfigFile($cmdline{'ConfigFile'});
CheckMandatoryOptions();

if( $opt{'UseSyslog'} ) {
  InitializeLogging();
}

# make sure work directory exists and is writeable
CheckWorkDirectory($opt{'WorkDirectory'})
  || LogFatalAndExit("can't set up work directory $opt{'WorkDirectory'}");

# find the files to send offsite
my @files = GetBackupFiles($opt{'BackupDirectory'});

# make the images
my $num_images = MakeFilesForImages($opt{'MaxImageSize'},
                                    $opt{'WorkDirectory'}, @files);

LogInfo "created $num_images sets of files"


__END__

=head1 NAME

offsite - prepares recent backups to be taken offsite

=head1 SYNOPSIS

offsite [options]

 Options:
   --config <f>		read configuration from <f>
   --nosyslog		log to stdout instead of syslog
   --facility <f>	log to syslog facility <f>
   --backupdir <d>	find backups in directory <d>
   --workdir <d>	create ISO images in directory <d>
   --blocksize <b>	write in multiples of <b> bytes
   --maxfilesize <b>	split files larger than <b> bytes
   --maximagesize <b>	don't put more than <b> bytes into one image
   --pwfile <f>		encrypt with passphrase from file <f>
   --dryrun		don't create any files
   --help		print a usage summary
   --man		read the full man page

=head1 DESCRIPTION

The B<offsite> program prepares backup files created by the B<backup> program
to be transferred to removable media to be taken offsite. This includes
splitting large files, splitting files across media size boundaries, and
encrypting the split files using GPG. The files selected to be taken offsite
are the most recent level zero backup of each filesystem, along with the most
recent level one backup if one is present.

The program will create one directory beneath the work directory for each
set of files to be put onto one media. Within this directory, files will be
split if they exceed a configurable maximum size, of if they will not fit
on one media. The C<--dryrun> option is useful to see which files would be
split and how much media you will need.

To secure the backup data being taken offsite, the files are encrypted
with GPG using conventional (symmetric) encryption. This mode requires no
keys or keyring for encryption or decryption; only a passphrase is used.
Files are split if necessary before being encrypted, so to restore from
offsite media you must decrypt all the files before reassembling them.

Originally this program was intended to produce images for DVD media, but
the image size and file size can be adjusted for CD media or any other
media. It is assumed that the output files will be made into ISO-9660
images, but this program does not attempt to create the images.

=head1 OPTIONS

Almost all options can be specified both on the command line and in the
configuration file. When an option is specified in both places, the value
supplied on the command line is used. The configuration file is described
in the L<"CONFIGURATION FILE"> section.

=over

=item B<--config I<f>>

Read configuration from file I<f>. If not specified, configuration is read
from F</etc/backup/backup.conf>. The configuration file is described
in the L<"CONFIGURATION FILE"> section.

=item B<--nosyslog>

Log to stdout instead of syslog.

=item B<--facility I<f>>

When using syslog, log to facility I<f>. The default is C<user>.

The corresponding configuration file option is C<SyslogFacility>.

=item B<--backupdir I<d>>

Look for backups in directory I<d>. Files ending in C<.bz2> are assumed to be
backups. There is no default; this option must be specified.

The corresponding configuration file option is C<BackupDirectory>.

=item B<--workdir I<d>>

Create subdirectories containing output files beneath directory I<d>. This
may be within the backup directory. There is no default; this option must
be specified.

The corresponding configuration file option is C<WorkDirectory>.

=item B<--blocksize I<b>>

When splitting and compressing files, work in multiples of I<b> bytes. The
larger this number, the more efficient C<dd> is. If the backups span
multiple discs, somewhere between 0 and I<b> bytes will be wasted at the
end of all but the last disc. The default is 4096.

The corresponding configuration file option is C<BlockSize>.

=item B<--maxfilesize I<b>>

Force a file to be split if it is larger than I<b> bytes. This is useful
to work around the inability of C<mkisofs> to add files larger than 2GB
to an ISO-9660 image. The default is 2000000000, which is slightly less
than 2GB.

The corresponding configuration file option is C<MaxFileSize>.

=item B<--maximagesize I<b>>

Put no more than I<b> bytes in one image. If I<b> is not a multiple of
the block size, then less than I<b> bytes will be in each full image.
The default is 4698112000, which is 99.9% of the capacity of a DVD.

The corresponding configuration file option is C<MaxImageSize>.

=item B<--pwfile I<f>>

Read the passphrase used for GPG encryption from file I<f>. GPG is used for
conventional (symmetric) encryption using no keys, only a passphrase.
The first line is read from I<f>, any newline is removed, and the result
is used as the passphrase. There is no default; this option must be
specified.

The corresponding configuration file option is C<PasswordFile>.

=item B<--dryrun>

Don't encrypt or create any files; just show what would be done. This is
useful to get an idea of how many images would be created and which files
would be split.

=item B<--help>

Print a usage summary and exit.

=item B<--man>

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

=cut
