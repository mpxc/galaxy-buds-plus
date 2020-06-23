#!/usr/bin/perl -w

# Copyright (C) 2020  Mario Preksavec
#
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
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

use strict;
use warnings;

use Net::Bluetooth;
use Digest::CRC qw(crc);
use Getopt::Long qw(GetOptions);
use Pod::Usage qw(pod2usage);

my %opts;
GetOptions(
  'help|?'    => \$opts{help},
  'addr|a=s'  => \$opts{addr},
  'set|s=s'   => \$opts{set},
  'debug|d'   => \$opts{debug},
);
pod2usage(-verbose => 99, -sections => [ qw(.*) ]) if ($opts{help} || !$opts{addr});

# Module hides some cruft
BEGIN {
  unshift(@INC, '.');
  require budsplus;
}

# Hash with all of the messages from the module
my %msgs = %BudsPlusMsgs::m;

# Used to resolve messages by their hash value
# It takes two arguments, a hash name and a value (returns the key name)
sub resolve_message {
  map { $_ = shift } my ($h, $f);
  map { if ($msgs{$h}{$_} == $f) { return $_ } } keys %{$msgs{$h}};
  return $f;
}

# Used to read everything into a single array
# It takes a file handle and array reference (returns 0 when done)
# Initially it was reading 256 byte chunks, but some messages were missing \0
sub budsplus_read_all {

  my ($fh, $ref, $r) = (shift, shift, undef);
  local $SIG{ALRM} = sub {};
  local $| = 1;

  while (1) {
    alarm 2;
    last if (!sysread($fh, $r, 1));
    alarm 0;
    # Each byte is a signed data type
    push(@$ref, unpack("c", $r));
    printf("\rGathering info (%d bytes)", scalar(@$ref));
  }

  print("\n");
  printf(">> Data dump: %s\n", join(",", @$ref)) if ($opts{debug});
  return 0;
}

# Used to calculate the CRC16-CCITT Xmodem type sums
# It takes binary data, returns the checksum
sub crc16ccitt {
  return crc(shift, 16, 0, 0, 0, 0x1021, 0, 0);
}

# [0] INDEX_SOM, LENGTH_SOM=1
# [1] INDEX_HEADER, LENGTH_HEADER=2
# [2] -||-
# [3] INDEX_PAYLOAD_START (MSG_ID)
# [4] DATA
# ...
# [N-3] INDEX_CRC, LENGTH_CRC=2
# [N-2] -||-
# [N-1] INDEX_EOM, LENGTH_EOM=1

# Used to extract payload from the frame
# It takes two arrays, input and output (on success returns 0, otherwise 1)
sub budsplus_extract_payload {

  my $ref = shift;
  my $ret = shift;

  my $som = shift(@$ref);
  if ($som ne $msgs{Msg}{SOM}) {
    printf(">> Unknown SOM (%02X != %02X)\n", $som, $msgs{Msg}{SOM}) if ($opts{debug});
    return 1;
  }

  # Header has 2 bytes
  my $head = (shift(@$ref) & 0xff) + ((shift(@$ref) & 0xff) << 8);

  # Some messages will need more work
  if ($head & 0x2000) {
    printf(">> Fragmented frames are unsupported (%d mod %d != 0)!\n", $head, 0x2000) if ($opts{debug});
  } elsif ($head & 0x1000) {
    printf(">> Message is a response (%d mod %d != 0)!\n", $head, 0x1000) if ($opts{debug});
  }

  # Actual size of the payload (data+crc)
  my $size = $head & 0x3ff;
  printf(">> Extracting payload (%d bytes)\n", $size) if ($opts{debug});

  # Return only the good stuff
  @$ret = splice(@$ref, 0, $size);

  my $eom = shift(@$ref);
  if ($eom ne $msgs{Msg}{EOM}) {
    printf(">> Unknown EOM (%02X != %02X)\n", $eom, $msgs{Msg}{EOM}) if ($opts{debug});
    return 1;
  }

  return 0;
}

# Used to check CRC and strip it from the message
# It takes a single array refence which gets modified
sub budsplus_crc_check {

  my $ref = shift;
  my $crc = ((pop(@$ref) & 0xff) << 8) + (pop(@$ref) & 0xff);
  my $check_crc = crc16ccitt(pack("c*", @$ref));

  if ($crc != $check_crc) {
    printf(">> CRC Failed (0x%04X != 0x%04X)!\n", $crc, $check_crc) if ($opts{debug});
    return 1;
  }

  printf(">> CRC Succeeded (0x%04X == 0x%04X)!\n", $crc, $check_crc) if ($opts{debug});
  return 0;
}

# Used to decode actual data message
# It takes two array references (on success returns 0, otherwise 1)
# Some messages are commented out because they were not tested (revision < 10)
sub budsplus_decode_data {

  my $ref = shift;
  my $msg = shift;

  printf(">> Data: %s\n", join(",", @$ref)) if ($opts{debug});

  my $id = shift(@$ref);
  my $type = resolve_message("MsgID", $id);

  if ($type eq $id) {
    printf(">> Unknown message type (%d)!\n", $id) if ($opts{debug});
    return 1;

  } elsif ($type eq "EXTENDED_STATUS_UPDATED") {
    $msg->{revision} = shift(@$ref);
    $msg->{earType} = shift(@$ref);
    $msg->{batteryLeft} = shift(@$ref);
    $msg->{batteryRight} = shift(@$ref);
    if (shift(@$ref) eq 1) { $msg->{coupled} = 1; } else { $msg->{coupled} = 0; }
    $msg->{primaryEarbud} = shift(@$ref);

    my $b2 = shift(@$ref);
    if ($msg->{revision} >= 5) {
      $msg->{placementL} = ($b2 & 0xF0) >> 4;
      $msg->{placementR} = ($b2 & 0xF);
      if ($msg->{placementL} == 1) { $msg->{wearingL} = 1; } else { $msg->{wearingL} = 0; }
      if ($msg->{placementR} == 1) { $msg->{wearingR} = 1; } else { $msg->{wearingR} = 0; }
#    } elsif ($b2 != 0) {
#      if ($b2 != 1) {
#        if ($b2 != 16) {
#          if ($b2 == 17) {
#            $msg->{wearingR} = 1;
#            $msg->{wearingL} = 1;
#          }
#        } else {
#          $msg->{wearingL} = 1;
#        }
#      } else {
#        $msg->{wearingR} = 1;
#      }
#    } else {
#      $msg->{wearingR} = 0;
#      $msg->{wearingL} = 0;
    }

    if ($msg->{revision} >= 3) {
      $msg->{batteryCase} = shift(@$ref);
    }

 #   if ($msg->{revision} <= 1) {
 #     if (shift(@$ref) == 1) { $msg->{ambientSound} = 1; } else { $msg->{ambientSound} = 0; }
 #     $msg->{ambientSoundVolume} = shift(@$ref);
 #     $msg->{equalizer} =  shift(@$ref);
 #   }

    if ($msg->{revision} >= 4) {
      if (shift(@$ref) == 1) { $msg->{ambientSound} = 1; } else { $msg->{ambientSound} = 0; }
      $msg->{ambientSoundVolume} = shift(@$ref);
      if (shift(@$ref) == 1) { $msg->{adjustSoundSync} = 1; } else { $msg->{adjustSoundSync} = 0; }
    }

    $msg->{equalizerType} = resolve_message("CardEqualizer", shift(@$ref));
    if (shift(@$ref) == 1) { $msg->{touchpadConfig} = 1; } else { $msg->{touchpadConfig} = 0; }

    my $b3 = shift(@$ref);
    $msg->{touchpadOptionLeft} = resolve_message("TouchpadActivity", ($b3 & 0xF0) >> 4);
    $msg->{touchpadOptionRight} = resolve_message("TouchpadActivity", ($b3 & 0xF));

#    if ($msg->{revision} >= 5 && $msg->{revision} < 7) {
#      $b2 = shift(@$ref);
#      $msg->{colorL} = ($b2 & 0xF0) >> 4;
#      $msg->{colorR} = ($b2 & 0xF);
#    }

#    if ($msg->{revision} == 6) {
#      if (shift(@$ref) == 1) { $msg->{outsideDoubleTap} = 1; } else { $msg->{outsideDoubleTap} = 0; }
#    } 

    if ($msg->{revision} >= 7) {
      if (shift(@$ref) == 1) { $msg->{outsideDoubleTap} = 1; } else { $msg->{outsideDoubleTap} = 0; }
      my $s1 = shift(@$ref) + (shift(@$ref) << 8);
      my $s2 = shift(@$ref) + (shift(@$ref) << 8);
      if ($s1 != $s2) {
        $msg->{deviceColor} = 0;
      } else {
        $msg->{deviceColor} = resolve_message("CardEarbuds", $s1);
      }
    }

    if ($msg->{revision} >= 8) {
      if (shift(@$ref) == 1) { $msg->{sideToneStatus} = 1; } else { $msg->{sideToneStatus} = 0; }
    }

    if ($msg->{revision} >= 9) {
      if (shift(@$ref) == 1) { $msg->{extraHighAmbient} = 1; } else { $msg->{extraHighAmbient} = 0; }
    }

  } elsif ($type eq "VERSION_INFO") {

    my ($b1, $str1, $out, $b2);
    $b1 = shift(@$ref);
    $msg->{Left_HW_version} = sprintf("rev%X.%X", ($b1 & 0xF0) >> 4, $b1 & 0xF);

    $b1 = shift(@$ref);
    $msg->{Right_HW_version} = sprintf("rev%X.%X", ($b1 & 0xF0) >> 4, $b1 & 0xF);

    if (shift(@$ref) == 0) { $str1 = "E"; } else { $str1 = "U"; }
    $out = sprintf("R175XX%s0A", $str1);
    $b1 = shift(@$ref);
    $b2 = shift(@$ref);
    if ($b2 <= 15) {
      $str1 = sprintf("%X", $b2);
    } else {
      $str1 = sprintf("%s", $msgs{MsgVersionInfo}{SWRelVer}[$b2 - 16]);
    } 
    $out .= sprintf("%s%s%s", $msgs{MsgVersionInfo}{SWYear}[($b1 & 0xF0) >> 4], $msgs{MsgVersionInfo}{SWMonth}[$b1 & 0xF], $str1);
    $msg->{Left_SW_version} = $out;

    if (shift(@$ref) == 0) { $str1 = "E"; } else { $str1 = "U"; }
    $out = sprintf("R175XX%s0A", $str1);
    $b1 = shift(@$ref);
    $b2 = shift(@$ref);
    if ($b2 <= 15) {
      $str1 = sprintf("%X", $b2);
    } else {
      $str1 = sprintf("%s", $msgs{MsgVersionInfo}{SWRelVer}[$b2 - 16]);
    }
    $out .= sprintf("%s%s%s", $msgs{MsgVersionInfo}{SWYear}[($b1 & 0xF0) >> 4], $msgs{MsgVersionInfo}{SWMonth}[$b1 & 0xF], $str1);
    $msg->{Right_SW_version} = $out;

    $msg->{Left_Touch_FW_Version} = sprintf("%x", shift(@$ref));
    $msg->{Right_Touch_FW_Version} = sprintf("%x", shift(@$ref));

  } elsif ($type eq "FOTA_DEVICE_INFO_SW_VERSION") {
    my $s = sprintf("FOTA_DEVICE_INFO_SW_VERSION-%s", pack("c", shift(@$ref)));
    $msg->{$s} = pack("c*", @$ref);

#  } elsif ($type eq "USAGE_REPORT") {
#    printf(">> Debug: %s\n", pack("c*", @$ref)) if ($opts{debug});
  }

  printf(">> Message id=%d, type=%s\n", $id, $type) if ($opts{debug});
  return 0;
}

sub budsplus_send {
  my $fh = shift;
  my @frame;

  # SOM (index=0, bytes=1)
  push @frame, $msgs{Msg}{SOM} & 0xff;

  # Header size (index=1, bytes=2)
  push @frame, scalar(@_) + 2;
  push @frame, 0;

  # Payload start (index=3, bytes=1)
  my $msgid = $msgs{MsgID}{shift()};
  if ($msgid) {
    push @frame, $msgid & 0xff;
  } else {
    print("Bad message id!\n");
    return 1;
  }

  # Data (index=4)
  foreach (@_) { push @frame, $_; }

  # CRC (bytes=2)
  my $crc = crc16ccitt(pack("C*", @frame[3..$#frame]));
  push @frame, $crc & 0xff;
  push @frame, $crc >> 8;

  # EOM (bytes=1)
  push @frame, $msgs{Msg}{EOM} & 0xff;

  printf(">> Frame: %s\n", join(",", @frame)) if ($opts{debug});

  if (syswrite($fh, pack("C*", @frame))) {
    print "Message sent!\n";
  } else {
    print "Sending message failed: $!\n";
    return 1;
  }

  return 0;
}

if ($opts{addr}) {

  # Create a RFCOMM client
  my $bt = Net::Bluetooth->newsocket("RFCOMM");
  die "RFCOMM Socket error $!\n" unless(defined($bt));

  # Connect device (Galaxy Buds+ uses port 1)
  if ($bt->connect($opts{addr}, 1) != 0) {
    die "RFCOMM Connect error: $!\n";
  } else {
    printf("Connected to %s\n", $opts{addr});
  }

  # File handle for reading and writing
  my $fh = $bt->perlfh();

  # Send config if set
  if ($opts{set}) {
    budsplus_send(\$fh, split(/[=,]/, $opts{set}));
  }

  # Always read
  my (@read, %data);
  budsplus_read_all(\$fh, \@read);

  while (@read) {
    my @payload;
    next if (budsplus_extract_payload(\@read, \@payload) != 0);
    next if (budsplus_crc_check(\@payload) != 0);
    next if (budsplus_decode_data(\@payload, \%data) != 0);
  }

  print("Decoded info:\n");
  foreach (sort(keys %data)) {
    printf("  %s => %s\n", $_, $data{$_});
  }

  close($fh);
}

__END__

=head1 NAME

budsplus - B<This program> will provide a simple interface to Galaxy Buds+ headset.

=head1 SYNOPSIS

budsplus [options...]

=head1 OPTIONS

=over 30

=item B<-?>, B<--help>

Prints a brief help message and exits.

=item B<-a>, B<--addr> [ MAC ]

Connect to Galaxy Buds+ address and decode the data it presents.

=item B<-s>, B<--set> [ KEY=VALUE ]

Set some config options (*):

=back

    SET_AMBIENT_MODE=[0-1]		(Off, On)
    AMBIENT_VOLUME=[0-3]		(Low, Medium, High, Extra high)
    EXTRA_HIGH_AMBIENT=[0-1]		(Off, On)

    EQUALIZER=[0-5]			(Normal, BassBoost, Soft, Dynamic, Clear, TrebleBoost)

    LOCK_TOUCHPAD=[0-1]			(Off, On)
    SET_TOUCHPAD_OPTION=[1-3,1-3]	(Voice command (Bixby), Ambient sound, Volume down/up)
    MSG_ID_OUTSIDE_DOUBLE_TAP=[0-1]	(Off, On)

    FIND_MY_EARBUDS_START
    FIND_MY_EARBUDS_STOP
    MUTE_EARBUD=[0-1,0-1]

* IMPORTANT NOTE: Only basic validation is performed on the first argument (KEY), all other data is set as specified (VALUE).

=over 30

=item B<-d>, B<--debug>

Display debug messages.

=back

=cut
