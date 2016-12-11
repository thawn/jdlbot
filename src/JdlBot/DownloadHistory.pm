package JdlBot::DownloadHistory;

use strict;
use warnings;

use Data::Dumper;

require Exporter;
our @ISA    = qw(Exporter);
our @EXPORT = qw(storeEntry listEntries getEntry resetHistory);

my @storage;


sub storeEntry {
	my ( $links, $title, $status ) = @_;
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
	$year += 1900;
	my $timestamp = sprintf("%d-%02d-%02d %02d:%02d", $year, $mon, $mday, $hour, $min );
	push(@storage, { 'date' => $timestamp, 'title' => $title, 'urls' => $links, 'status' => $status });
	return 1;
}

sub listEntries {
	if (@storage) {
		return \@storage;
	} else {
		return 0;
	}
}

sub getEntry {
	my $index = $_[0];
	if ($storage[$index]) {
		return $storage[$index];
	} else {
		return 0;
	}
}

sub clearHistory {
	@storage = ();
	return 1;
}

1;