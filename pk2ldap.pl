#!/usr/bin/perl

use strict;
use warnings;
use MIME::Base64;
use Term::ReadKey;
use Getopt::Long;
Getopt::Long::Configure ("bundling");
use Net::LDAP;
use Net::LDAP::Entry;

$|=1;
my $argv = join ' ', @ARGV; $argv =~ s/(\s*-w\s+)\S+(.*?)/$1$2/;

my $passwordfile = $ENV{PASSFILE} if defined $ENV{PASSFILE} && -r $ENV{PASSFILE};
my $password = '';
my $help = 0;
my $binddn = "$ENV{LDAPUSER},$ENV{BASEDN}" if defined $ENV{LDAPUSER} && defined $ENV{BASEDN};
my $basedn = "$ENV{BASEDN}" if defined $ENV{BASEDN};
my $ro = 0;
my $debug = 0;
my$update = 0;
GetOptions(
	'help|h' => sub { $help = 1 },
	'update|u' => \$update,
	'debug|d:1' => \$debug,
	'binddn|D=s' => \$binddn,
	'basedn|b=s' => \$basedn,
	'password|w=s' => \$password,
	'passwordfile|W=s' => \$passwordfile,
	'readonly|r' => sub { $ro = 1 },
);
die <<DIE if $help || !$binddn || !$basedn;
Usage: $0 [OPTIONS]
	-h:	Display this help message and exit
	-u:	Update
	-d:	Debug
	-D:	Bind DN (Default: $binddn)
	-b:	Base DN (Default: $basedn)
	-w:	LDAP Manager password
	-W:	File containing LDAP Manager password (Default: $passwordfile)
	-r:	Read-only.  Do not update LDAP.
DIE

if ( $passwordfile && -f $passwordfile && -r _ ) {
	chomp($password = qx{cat $passwordfile}); 
} elsif ( !$password ) {
	print "Enter LDAP Password: ";
	ReadMode 'noecho';
	chomp($password = ReadLine);
	ReadMode 'normal';
}
my $ldap = Net::LDAP->new('ldap.example.com', version => 3);
my $bind = $ldap->bind($binddn, password=>$password);
if ( $bind->code ) {
	die "Invalid DN and/or password: $binddn\n";
}
undef $password; undef $passwordfile;

my %pk;
my $c = 0;
open PK, "Finger.pk";
open TMP, ">tmp/joe.pk";
do { do { $pk{$c++} = $_; print TMP "$_\n"; } if defined $_ } while read PK, $_, 1063;
close TMP;
close PK;

print "Total finger prints: ", (scalar keys %pk), "\n";
$c = 0; my $d = 0;
foreach ( keys %pk ) {
	$_ = $pk{$_};
	my ($uid) = (/^(\w+)/);
	my $encoded = encode_base64($_); $encoded =~ s/\n/\n /g;
	my $search = $ldap->search(
		base => "$basedn",
		filter => "uid=$uid",
	);
	$search->code && die $search->error;
	if ( my $entry1 = $search->entry(0) ) {
		my $dn = $entry1->dn();
		my $entry2 = Net::LDAP::Entry->new;
		$entry2->dn($dn);
		$entry2->changetype('modify');
		$entry2->add(objectClass => 'local') unless grep { /^local$/i } $entry1->get_value('objectClass');
		$entry2->add(localFollettID => $uid) unless $entry1->get_value('localFollettID');
		$entry2->replace(localFSSpk => $encoded);
		if ( $update ) {
			my $update = $entry2->update($ldap);
			die $update->error."\n" if $update->code;
			print "Updated finger print for $uid.\n";
		} else {
			print "Read finger print for $uid.\n";
			$entry2->dump() if $debug;
		}
		$c++;
	} else {
		print STDERR "No Posix account for finger print $uid.\n";
		$d++;
	}
}
if ( $update ) {
	print "Successfully stored $c finger prints in LDAP.\n";
	print "Failed storing $d finger prints.\n";
}

# OLD ###########################################################
#my $pk = join '', (@_ = <PK>);
#foreach ( @passwd ) {
#	chomp;
#	$pk =~ s/([^\p{IsPrint}])$_/$1\n$_/;
#}
#	print "dn: uid=$uid,ou=People,o=local\n";
#	print "add: objectClass\n";
#	print "objectClass: local\n\n";
#	print "dn: uid=$uid,ou=People,o=local\n";
#	print "add: localFingerPrint\n";
#	print "localFingerPrint: $encoded\n\n";
