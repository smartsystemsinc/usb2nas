#!/usr/bin/env perl

# Force me to write this properly

use strict;
use warnings;

# Modules

use Carp;              # Built-in
use Config::Simple;    # dpkg libconfig-simple-perl || cpan Config::Simple
use English qw(-no_match_vars);                 # Built-in
use Getopt::Long qw(:config no_ignore_case);    # Built-in
use Pod::Usage;                                 # Built-in
use POSIX qw(strftime);                         # Built-in
use Fcntl ':flock';                             # Built-in

INIT {
    if ( !flock main::DATA, LOCK_EX | LOCK_NB ) {
        print "$PROGRAM_NAME is already running\n" or croak $ERRNO;
        exit 1;
    }
}

## no critic (RequireLocalizedPunctuationVars)
BEGIN {
    $ENV{Smart_Comments} = " @ARGV " =~ /--debug/xms;
}
use Smart::Comments -ENV
    ;    # dpkg libsmart-comments-perl || cpanm Smart::Comments

our $VERSION = '0.3';

# Set variables
my $bakdir = '/root/backups';
my $bakdir_full;
my $base_device;
my $base_dir = $ENV{'HOME'} . '/.local/share/SS/usb2nas';
my $config   = "$base_dir/config.ini";
my $email;
my $real_device;
my $real_device_base;
my $ref_labels;
my $ref_partitions;
my $source_dir;
my $symlink;
my @symlinks;

# Ensure directory exists
if ( !-d $base_dir ) { system "mkdir -p $base_dir" and croak $ERRNO; }

# Try to read in parameters from the config file
if ( -f "$config" ) {
    my $cfg = Config::Simple->new();
    $cfg->read("$config") or croak $ERRNO;
    $email = $cfg->param('email');
}

# Override paramters if entered on the command line
GetOptions(
    'help|h'    => \my $help,
    'debug'     => \my $debug,     # dummy variable
    'man'       => \my $man,
    'version'   => \my $version,
    'email|e:s' => \$email,

) or pod2usage( -verbose => 0 );

if ($help) {
    pod2usage( -verbose => 0 );
}
if ($man) {
    pod2usage( -verbose => 2 );
}
if ($version) {
    die "$PROGRAM_NAME v$VERSION\n";
}

if ( $EFFECTIVE_USER_ID != 0 ) {
    die "This script can only run as root\n";
}

# Verify that e-mail makes reasonable sense
if ( $email !~ m/^\w+[@][\d[:alpha:]\-]{1,}[.]{1,}[\d[:alpha:]-]{2,6}$/xms ) {
    croak "Invalid e-mail address syntax\n";
}

# Verify that non-core external programs are installed
check_external_programs();

# Get symlinks
get_symlinks();
### @symlinks

# Run the main program; if @symlinks is empty then exit
LOOP:
if (@symlinks) {
    foreach (@symlinks) {
        main($_);
    }
}
else {
    print "Finished\n" or croak $ERRNO;
    exit;
}

# Get a new list of symlinks
get_symlinks();

goto LOOP;

# Subprocedures

sub main {

    $symlink = shift or croak "Missing paramter - safety symlink\n";
    chomp $symlink;
    ### $symlink
    # Base device should be e.g. 'sda'
    ($base_device) = ( $symlink =~ /( sd[[:lower:]])/xms );
    ### $base_device
    # Real device should be e.g. /sys/block/sda but need to make sure
    $real_device_base = `readlink /sys/block/$base_device`;
    chomp $real_device_base;
    ### $real_device_base
    ($real_device) = ( $real_device_base =~ /( \/block\/sd[[:lower:]])/xms );
    $real_device = '/sys' . $real_device;
    chomp $real_device;
    ### $real_device

    verify();

    backup();

    return 0;
}

sub check_external_programs {

    if ( `which rsync` eq q{} ) {
        print "rsync not found. Attempting to install.\n" or croak $ERRNO;
        system 'sudo apt-get install rsync --yes' and croak $ERRNO;
    }

    if ( `which mail` eq q{} ) {
        print "heirloom-mailx not found. Attempting to install.\n"
            or croak $ERRNO;
        system 'sudo apt-get install heirloom-mailx --yes' and croak $ERRNO;
    }

    if ( `which msmtp` eq q{} ) {
        print "msmtp not found. Attempting to install.\n" or croak $ERRNO;
        system 'sudo apt-get install msmtp --yes' and croak $ERRNO;
    }
    return 0;
}

sub get_symlinks {
    opendir DIR, '/dev' or croak $ERRNO;
    @symlinks = grep {/safetysd[[:lower:]]\b/xms} readdir DIR;
    @symlinks = sort @symlinks;
    closedir DIR or croak $ERRNO;
    return 0;
}

sub verify {

    if (   is_usb() == 0
        && is_using_sd_driver() == 0
        && is_large_enough() == 0 )
    {
        my $cur_time = strftime '%c', localtime;

        ( $ref_labels, $ref_partitions ) = get_label()

            or system
            "echo \"No labels found. Please label any partitions needed for backup.\" | mail -s \"Backup report from $real_device at $cur_time\" $email";
        ### $ref_labels
        ### $ref_partitions
    }
    else {
        system "rm /dev/$symlink" and croak $ERRNO;
        print "Not using SD driver and/or a USB disk of sufficient capacity\n"
            or croak $ERRNO;
        next;
    }
    return 0;
}

sub is_usb {
    if ( $real_device_base =~ /^.*\/usb[\d].*/xms ) {
        return 0;
    }
    else {
        return 1;
    }
}

sub is_using_sd_driver {
    my $device_uevent = "$real_device/device/uevent";
    my $uevent        = `cat $device_uevent`;
    if ( $uevent =~ /^DRIVER=sd/xms ) {
        return 0;
    }
    else {
        return 1;
    }
}

sub is_large_enough {
    my $size_in_gb = 512 * `cat $real_device/size` / 1000 / 1000 / 1000;
    ### $size_in_gb
    if ( $size_in_gb > 127 ) {
        return 0;
    }
    else {
        return 1;
    }
}

sub get_label {

    my $local_label;
    my $cur_device;
    my $i = 1;
    my @local_labels;
    my @local_partitions;
    while ( $i < 7 ) {
        $cur_device = $base_device . $i;
        $local_label
            = `blkid /dev/$cur_device | grep -oP 'LABEL=\\K.*' | sed 's/UUID=.*//' | sed 's/TYPE=.*//' | sed 's/"//g' | sed 's/.*://' | sed 's/ //g'`;
        chomp $local_label;

        if ( !length $local_label ) {
            next;
        }
        else {
            push @local_labels,     $local_label;
            push @local_partitions, $cur_device;
        }
    }
    continue {
        $i++;
    }
### @local_labels
### @local_partitions
    return \@local_labels, \@local_partitions;
}

sub get_serial {
    my $serial = `udevadm info --query=all --path=/sys/block/$base_device`;
    ($serial) = ( $serial =~ /ID_SERIAL_SHORT=(.*?)\n/xms );
    return $serial;
}

sub backup {
    my @labels     = @{$ref_labels};
    my @partitions = @{$ref_partitions};
ITERATION:
    for my $i ( 0 .. $#labels ) {
        my $label     = $labels[$i];
        my $partition = $partitions[$i];
        ### $label
        ### $partition
        my $serial = get_serial();
        chomp $serial;
        ### $serial
        $bakdir_full = $bakdir . qw{/} . $label . qw{-} . $serial;
        chomp $bakdir_full;
        ### $bakdir_full
        $source_dir = "/mnt/$partition";
        my $local_symlink;
        $local_symlink = $symlink;
        $local_symlink =~ s/safety.*/safety$partition/xms;
        $local_symlink = "/dev/$local_symlink";

        # # FIXME We really need a better way to handle the flow
        # # of the program; it should stop this earlier if possible
        # if ( !-e $local_symlink ) {
        #     print "Finished\n" or croak $ERRNO;
        #     exit;
        # }

        ### $source_dir
        ### $local_symlink
        # my $log = '/home/cory/Desktop/usb.txt';
        # open my $OUTPUT, '>>', "$log"
        #     or croak "Unable to open log file $log\n";
        # print {$OUTPUT} "$symlink\n"     or croak $ERRNO;
        # print {$OUTPUT} "$bakdir_full\n" or croak $ERRNO;
        # close $OUTPUT or croak "Unable to close log file $log\n";
        system "mkdir -p $bakdir_full" and croak $ERRNO;

        if ( !-d $source_dir ) { mkdir $source_dir or croak $ERRNO; }
        system "mount $local_symlink $source_dir";
        sleep 2;
        system

            # Mind the trailing / at the end of $source_dir
            "rsync --archive --verbose \"$source_dir/\" \"$bakdir_full\" 2>&1";
        my $rsync_status_return = $CHILD_ERROR >> 8;
        my $rsync_status_error  = $ERRNO;
        my $rsync_output;

        if ( $rsync_status_return != 0 && $rsync_status_error != 0 ) {
            $rsync_output
                = "Rsync reported issues.\nrsync error code: $rsync_status_return;\nrsync error message: $rsync_status_error\n";
            ### $rsync_output
        }
        else {
            $rsync_output = "Backup completed successfully.\n";
            ### $rsync_output
        }

        # NOTE: This seems to remove the safety symlink as well
        system "umount $source_dir" and croak $ERRNO;
        system "rmdir $source_dir"  and croak $ERRNO;
        system "rm /dev/$symlink"   and croak $ERRNO;
        my $cur_time = strftime '%c', localtime;
        system
            "echo \"Backup complete. Rsync output: $rsync_output\" | mail -s \"Backup report from $source_dir at $cur_time\" $email"
            and croak $ERRNO;

        next ITERATION;
    }
    return 0;
}

__END__

=pod Changelog

=begin comment

Changelog:

0.3:
    -Refactored based on improvements made in ssbak2bak v0.1
    -Added a configuration file as a result; currently just stores the e-mail address
    -Added basic checks for installed utility programs
    -Improved the documentation

0.2:
    -Refactored to ensure all eligible drives are dealt with, even if they're
     plugged in partway through
    -Refactored to allow the script to back up _all_ labelled partitions
     instead of just the first partition
    -Updated the documentation accordingly along with some minor usability
     improvements when used with graphical POD viewers

0.1:
    -Initial version

=end comment

=cut

# Documentation
=pod

=head1 NAME

usb2nas -- Backs up to an external device based on a udev rule

=head1 USAGE

    perl usb2nas.pl     [OPTION...]
    -h, --help          Display this help text
        --debug         Enables debug mode
        --man           Displays the full embedded manual
        --version       Displays the version and then exits
    -e, --email         E-mail address to send reports to

=head1 DESCRIPTION

Intended to be used in conjunction with a udev rule, this script looks at all
drives on the system and then performs several qualifying tests on it; should
it be a USB drive using the sd driver, larger than 128 gigabytes, and with a
label of some sort it will be backed up, and then notify you via e-mail.
Requires root access and pre-configuration of the mail elements, detailed under
L<CONFIGURATION|CONFIGURATION>.

=head1 REQUIRED ARGUMENTS

Requires an e-mail address, as detailed in L<USAGE|USAGE>.

=head1 OPTIONS

See L<USAGE|USAGE>. There's really nothing to configure here at the moment
aside from local debug output.

=head1 DIAGNOSTICS

Ensure that your .msmtprc, your ~/.mailrc, and your udev rule are configured
correctly; ensure also that L<rsync(1)|rsync(1)> is installed correctly.
Sample configurations for the udev rule and msmtp are provided below. Don't
forget to chmod ~/.msmtprc to 600 (r-w only for the user)

Failing all of that, ensure that the partition to be backed up has a label. Any
label. Labels are part of the backup path, to help keep it human-readable.

=head1 EXIT STATUS

0 for success, 1 for either quitting prematurely due to another instance running
or for other issues which will be present in the output.

=head1 CONFIGURATION

Sample /etc/udev/rules.d/backup.rules:

    # Backup rules
    SUBSYSTEM=="block", ACTION=="add", KERNEL=="sd*", SYMLINK+="safety%k"
    SUBSYSTEM=="block", ACTION=="add", RUN+="/home/foo/.local/bin/usb2nas/usb2nas.pl | at now"

What this does is check for any drive that is successfully added, then creates
a symlink to it and every partition on it for safety's sake. It then runs the
script explicitly, piping the whole thing into L<at(1)|at(1)> to avoid blocking
udev. Note that this rule will run for every partition on the drive; for that
reason, this script will only allow itself to be started once, using
Fcntl ':flock'.

It also requires e-mail to be configured, specifically requiring
L<mail(1)|mail(1)> and L<msmtp(1)|msmtp(1)>. You'll need to add 'set
sendmail="/usr/bin/msmtp"' to your ~/.mailrc or /etc/mailrc as well.
For reference, here's a sample .msmtprc:

    account Test
    host 10.100.100.115
    port 1025
    protocol smtp
    from foo@mycompany.com
    auth login
    user foo.bar
    password mySecurePass123
    logfile ~/.msmtp.test.log
    account default: Test

For convenience, all of the required parameters can be put into a simple INI
config file in '$HOME/.local/share/SS/usb2nas', e.g.:

    email=foo@mycompany.com

=head1 DEPENDENCIES

Perl:

    -Perl of a recent vintage (developed on 5.18.2)
    -Config::Simple; (cpan Config::Simple or dpkg libconfig-simple-perl)
    -Smart::Comments (cpanm Smart::Comments or dpkg libsmart-comments-perl)
        -The call for this can be commented out at the top of the script if
         this functionality is unneeded

External:

    -readlink (coreutils)
    -rsync (rsync)
    -mail (heirloom-mailx)
    -msmtp (msmtp)
    -udev (udev)
    -udev rule

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

Report any bugs found to either the author or to the SmartSystems support
account, <support@smartsystemsaz.com>

=head1 AUTHOR

Cory Sadowski <cory@smartsystemsaz.com>

=head1 LICENSE AND COPYRIGHT

(c) 2015 SmartSystems, Inc.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut
