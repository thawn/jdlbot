package JdlBot::DownloadHistory;

use strict;
use warnings;

use Data::Dumper;

require Exporter;
our @ISA    = qw(Exporter);
our @EXPORT = qw(storeEntry listEntries getEntry resetHistory);

my @storage;


sub storeEntry {
	my ( $links, $title, $success ) = @_;
	
	my $timestamp = localtime();
	push(@storage, { 'date' => $timestamp, 'title' => $title, 'urls' => $links, 'success' => $success });
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