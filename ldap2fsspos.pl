#!/usr/bin/perl

# Used for converting data to FSS mass import data base for POS

use strict;
use warnings;
use Net::LDAP;
use Net::LDAP::Entry;

my $ldap = Net::LDAP->new('ldap.example.com', version => 3);
my $bind = $ldap->bind("cn=Manager,o=local", password=>'secret');
$bind->code && die "Cannot bind anonymously\n";

my $filter = "(|(&(objectClass=qmailuser)(accountStatus=active)(|(description=Staff)(description=Faculty)(description=Student)(description=Students)))(skyward-ALPHAKEY=*))";
my @attrs = qw{uid sn givenname skyward-GRAD-YR skyward-GENDER postalAddress postalCode homePhone skyward-FEDERAL-ID-NO};
my $search = $ldap->search(
	base=>"ou=People,o=local",
	filter => "$filter",
	attrs => @attrs,
);
print "StudentId\tPIN\tLastName\tFirstName\tGrade\tGender\tAddress\tZip\tPhone#\tSSN\tSchoolName\tDistrictName\n";
for my $i ( 0..$search->count ) {
	if ( my $entry = $search->entry($i) ) {
		my ($city, $state) = ('', '');
		if ( my $zip = $entry->get_value('postalCode') ) {
			my $cs = qx{wget -O /dev/stdout http://www.city-data.com/zips/$zip.html 2>/dev/null | grep -e "^City: <a href="};
			$cs =~ s/.*?>//; $cs =~ s/<.*//;
			($city, $state) = ($cs =~ /(.*?),\s+(\w{2})$/);
		}
		$city ||= ''; $state ||= '';
		print join("\t", (map { $entry->get_value($_) || '' } qw{uid uid sn givenname skyward-GRAD-YR skyward-GENDER postalAddress}));
		print "\t$city\t$state\t";
		print join("\t", (map { $entry->get_value($_) || '' } qw{postalCode homePhone skyward-FEDERAL-ID-NO}));
		print "\tOrg Name\tOrg Name\n";
	}
}
