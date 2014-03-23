#!/usr/bin/perl -w

# bwave2mbox.pl v0.1 - A BlueWave to mbox converter
# Author: Alberto Garcia <berto@igalia.com>, 2013
# BlueWave format description: http://webtweakers.com/swag/MAIL/0023.PAS.html

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;
use Fcntl qw(SEEK_SET SEEK_CUR);
use MIME::Base64;
use MIME::QuotedPrint;
use Date::Parse;
use POSIX qw(strftime setlocale LC_TIME);

# Some variables that you might want to change
# $ENV{TZ} = 'Europe/Madrid';
setlocale (LC_TIME, 'C');
my $charset = 'cp437';
my $unzip = '/usr/bin/unzip';

my %area_name;
my %area_descr;
my %msg_offset;
my %num_msgs;
my %messages;

# Check if unzip is available
if (!-x $unzip) {
    print "$unzip not found\n";
    exit 1;
}

# Check command-line parameters
if ($#ARGV < 1) {
    print "Usage: bwave2mbox.pl <packet1> <packet2> ... <outdir>\n";
    exit 1;
}

my $outdir = pop(@ARGV);

if (!-d $outdir) {
    print "Output directory $outdir does not exist\n";
    exit 1;
}

foreach my $packet (@ARGV) {
    if (!-f $packet) {
        print "Input file $packet not found\n";
        exit 1;
    }
}

# Create temporary dir and process packets
my $tmpdir = `mktemp -d /tmp/bwave2mbox.XXXXXX`;
chomp($tmpdir);
foreach my $packet (@ARGV) {
    print "Processing $packet...";
    process_packet ($packet, $outdir, $tmpdir);
    print "\n";
}
rmdir($tmpdir);

# Exit program
exit 0;

sub encode_header {
    my $hdr = shift;
    $hdr =~ s/\0//g;
    $hdr =~ s/\s*$//;
    my $qp = encode_qp($hdr,'');
    if ($qp eq $hdr) {
        return $hdr;
    } else {
        if (int((length($hdr) + 2) / 3) * 4 >= length($qp)) {
            return "=?${charset}?Q?${qp}?=";
        } else {
            return "=?${charset}?B?" . encode_base64($hdr, '') . "?=";
        }
    }
}

# Remove MSGID header and fix newline characters.
sub fix_body {
    my $body = shift;
    $body =~ s/[\x0a\x20]\x01((FLAGS|MSGID|NOTE|PID|REPLY|Received):|FMPT)(.*?)\x0d//g;
    $body =~ s/^\x20(.*?\x0d*[^\x20])/$1/;
    $body =~ s/\x0a//g;
    $body =~ s/\x0d/\n/g;
    return $body;
}

# Read name and description of each area
sub read_areas {
    my $filename = shift;
    my $number;
    open (INPUT, $filename);
    binmode (INPUT);
    sysseek (INPUT, 0x04ce, SEEK_SET);
    while (sysread (INPUT, $number, 6)) {
        my ($name, $descr);
        sysread (INPUT, $name, 21);
        sysread (INPUT, $descr, 50);
        $number =~ s/\0//g;
        $name =~ s/\0//g;
        $descr =~ s/\0//g;
        $area_name{$number} = lc($name);
        $area_descr{$number} = $descr;
        sysseek (INPUT, 3, SEEK_CUR);
        undef $number;
    }
    close (INPUT);
}

# Read the location of all messages
sub read_offsets {
    my $filename = shift;
    my $area;
    open (INPUT, $filename);
    binmode (INPUT);
    while (sysread (INPUT, $area, 6)) {
        my ($nmsgs, $offset);
        $area =~ s/\0//g;
        sysread (INPUT, $nmsgs, 2);
        sysseek (INPUT, 2, SEEK_CUR);
        sysread (INPUT, $offset, 4);
        $msg_offset{$area} = unpack('V', $offset);
        $num_msgs{$area} = unpack('v', $nmsgs);
        undef $area;
    }
    close (INPUT);
}

# Read all messages
sub read_messages {
    my $headers = shift;
    my $body = shift;
    open (INPUT, $headers);
    open (BODY, $body);
    binmode (INPUT);
    binmode (BODY);
    foreach my $area (keys(%num_msgs)) {
        my @messages;
        my $offset = $msg_offset{$area};
        my $nmsgs = $num_msgs{$area};
        sysseek (INPUT, $offset, SEEK_SET);
        for (my $i = 0; $i < $nmsgs; $i++) {
            my %message;
            my ($sender, $rcpt, $subject, $date);
            my ($msgoff, $msglen, $body, $id);
            my ($msgnum, $msgprev, $msgnext);
            sysread (INPUT, $sender, 36);
            sysread (INPUT, $rcpt, 36);
            sysread (INPUT, $subject, 72);
            sysread (INPUT, $date, 20);
            sysread (INPUT, $msgnum, 2);
            sysseek (INPUT, 4, SEEK_CUR);
            sysread (INPUT, $msgoff, 4);
            sysread (INPUT, $msglen, 4);
            sysseek (INPUT, 8, SEEK_CUR);

            $date =~ s/\0//g;
            $msgnum = unpack('v', $msgnum);
            $msgoff = unpack('V', $msgoff);
            $msglen = unpack('V', $msglen);
            sysseek (BODY, $msgoff, SEEK_SET);
            sysread (BODY, $body, $msglen);

            $message{sender} = encode_header($sender);
            $message{rcpt} = encode_header($rcpt);
            $message{subject} = encode_header($subject);
            $message{date} = str2time($date);
            $message{id} = "$msgnum.$message{date}.$i\@$area_name{$area}";
            $message{body} = fix_body($body);
            push (@messages, \%message);
        }
        $messages{$area} = \@messages;
    }
    close (INPUT);
    close (BODY);
}

# Write all messages to mbox files
sub write_messages {
    my $dir = shift;
    foreach my $areanumber (sort(keys(%num_msgs))) {
        my $areaname = $area_name{$areanumber};
        my $filename = "$dir/$areaname";
        open (OUTFILE, ">>$filename");
        my $areadescr = encode_header($area_descr{$areanumber});
        my @messages = @{$messages{$areanumber}};
        foreach (@messages) {
            my %message = %{$_};
            my $date = strftime("%a, %d %b %Y %H:%M:%S %z", localtime($message{date}));
            my $fromdate = strftime("%a %b %d %H:%M:%S %Y", localtime($message{date}));
            my $msglen = length($message{body}) + 1;
            print OUTFILE <<EOF
From localhost ${fromdate}
From: $message{sender} <fidonet\@localhost>
To: $message{rcpt} <${areaname}\@localhost>
Subject: $message{subject}
Date: ${date}
X-Area-Description: ${areadescr}
Message-ID: <$message{id}>
MIME-Version: 1.0
Content-Type: text/plain; charset=${charset}
Content-Disposition: inline
Content-Transfer-Encoding: 8bit
Content-Length: $msglen

$message{body}

EOF
        }
        close (OUTFILE);
    }
}

# Process BlueWave packets
sub process_packet {
    my $packet = shift;
    my $outdir = shift;
    my $tmpdir = shift;
    %area_name = %area_descr = %msg_offset = %num_msgs = %messages = ();
    system($unzip, '-q', '-LL', $packet, '*.inf', '*.mix', '*.fti', '*.dat', '-d', $tmpdir);
    my @inffiles = glob("$tmpdir/*.inf");
    if (@inffiles) {
        my $prefix = $inffiles[0];
        $prefix =~ s/\.inf$//;
        read_areas("$prefix.inf");
        read_offsets("$prefix.mix");
        read_messages("$prefix.fti", "$prefix.dat");
        write_messages($outdir);
    } else {
        print STDERR "Error processing $packet\n";
    }
    unlink(glob("$tmpdir/*"));
}
