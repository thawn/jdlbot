package JdlBot::DownloadHistory;

use strict;
use warnings;

require Exporter;
our @ISA    = qw(Exporter);
our @EXPORT = qw(storeEntry listEntries getEntry resetHistory);

my @storage;


sub storeEntry {
	my ( $links, $filter, $tv_episode, $status ) = @_;
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
	$year += 1900;
	$mon += 1;
	my $timestamp = sprintf("%d&#8209;%02d&#8209;%02d&nbsp;%02d:%02d", $year, $mon, $mday, $hour, $min );
	push(@storage, { 'date' => $timestamp, 'title' => $filter->{'title'}, 'filter'=>$filter, 'episode' => $tv_episode, 'urls' => $links, 'status' => $status });
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