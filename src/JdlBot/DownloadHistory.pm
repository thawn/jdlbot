package JdlBot::DownloadHistory;

use strict;
use warnings;

use Data::Dumper;

require Exporter;
our @ISA    = qw(Exporter);
our @EXPORT = qw(storeEntry listEntries getEntry resetHistory);

my @storage;


sub storeEntry {
	my ( $links, $filter ) = @_;
	
	my $timestamp = localtime();
	my $title;
	if ($filter->{'new_tv_last'}) {
		$title= $filter->{'title'} . " " . $filter->{'new_tv_last'}->[0];
	} else {
		$title= $filter->{'title'};
	}
	push(@storage, { 'date' => $timestamp, 'title' => $title, 'urls' => $links, 'filter' => $filter });
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