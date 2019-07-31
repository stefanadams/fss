#!/usr/bin/perl -w

use strict;
use Net::MAC;
use Getopt::Long;
use Spreadsheet::ParseExcel::Simple;

my $headerrow = 1;
GetOptions(
	'headerrow|r' => sub { $headerrow = 0 },
);

my @columns = qw{owner username compname serial lanmac wlanmac brand model type description};
my $xls = Spreadsheet::ParseExcel::Simple->read($ARGV[0]);
foreach my $sheet ( $xls->sheets ) {
if ( $headerrow ) {
	next unless $sheet->has_data;
	local @_ = map { lc($_) } $sheet->next_row if $sheet->has_data;
	die "Columns must be ${\(join ',', @columns)}\n" unless compare_arrays(\@_, \@columns);
	@columns = @_;
}
while ( $sheet->has_data ) {
	local @_ = $sheet->next_row;
	print STDERR join '-=-', @_, "\n";
	my %device = ();
	foreach ( @columns ) {
		$device{$_} = shift @_;
		$device{$_} = eval {
			my $mac = Net::MAC->new(mac => $device{$_});
			$mac = $mac->convert(delimiter => ':');   
			$mac->get_mac();
		} if /mac$/i;
	}
	next unless $device{compname} && $device{serial} && $device{lanmac} && $device{wlanmac};
#	print STDERR qq{ldapsearch -LLL "(&(cn=$device{compname})(deviceSerialNumber=$device{serial})(deviceLANMAC=$device{lanmac})(deviceWLANMAC=$device{wlanmac}))" deviceCurrentUser deviceCheckInTimeStamp deviceCheckOutTimeStamp deviceLastUser deviceReturnedBy | grep -v -e "^dn: "};
	chomp(my $ls = qx{. /etc/profile.d/ldaptools.sh ; ldapsearch -LLL "(&(cn=$device{compname})(localDeviceSerialNumber=$device{serial})(localDeviceLANMAC=$device{lanmac})(localDeviceWLANMAC=$device{wlanmac}))" localDeviceCurrentUser localDeviceCheckInTimeStamp localDeviceCheckOutTimeStamp localDeviceLastUser localDeviceReturnedBy | grep -v -e "^dn: "});
	print qq{dn: cn=$device{compname},ou=Devices,o=local\nobjectClass: top\nobjectClass: localDevice\ncn: $device{compname}\nlocalDeviceName: $device{compname}\nlocalDeviceLANMAC: $device{lanmac}\nlocalDeviceWLANMAC: $device{wlanmac}\nlocalDeviceSerialNumber: $device{serial}\nlocalDeviceBrand: $device{brand}\nlocalDeviceModel: $device{model}\nlocalDeviceType: $device{type}\nlocalDeviceLocation: $device{owner}\nlocalDeviceDescription: $device{description}\n$ls\n};
}
}

sub compare_arrays {
	my ($first, $second) = @_;
	no warnings;
	return 0 unless @$first == @$second;
	for (my $i = 0; $i < @$first; $i++) {
		return 0 if $first->[$i] ne $second->[$i];
	}
	return 1;
}
