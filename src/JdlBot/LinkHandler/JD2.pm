
package JdlBot::LinkHandler::JD2;

use strict;
use warnings;

use LWP::Simple qw($ua get);
use URI::Escape;
use Data::Dumper;
use Log::Message::Simple qw(msg error);

use JdlBot::UA;
use JdlBot::DownloadHistory;

$ua->timeout(5);
$ua->agent( JdlBot::UA::getAgent() );
$ua->default_header( 'Referer' => 'http://localhost:9666/flashgot' );

#  Returns 1 for success, 0 for failure.
sub processLinks {
	my ( $links, $filter, $tv_episode, $dbh, $config ) = @_;

	my $jdInfo =
	  $config->{'jd_address'} . ":" . $config->{'jd_port'} . "/flashgot";

	my $c = get("http://$jdInfo");
	if ( !$c ) {
		JdlBot::DownloadHistory::storeEntry( $links, $filter, $tv_episode, "failed to connect to jDownloader" );
		error( "... failed to connect to jDownloader API interface.", 1 );
		return 0;
	}

	my %data = (
		'source' => 'http://localhost',
		'urls'   => join( "\r\n", @$links ),
	  );

	if ($filter->{'autostart'} eq 'TRUE') {
		$data{'autostart'} = 1;
	}
	if ($filter->{'path'}){
		$data{'dir'} = $filter->{'path'};
	}
	my $response = $ua->post( "http://$jdInfo", \%data );
	if ( $response->is_success ) {
		msg( "... success.", 1 );
		JdlBot::DownloadHistory::storeEntry( $links, $filter , $tv_episode, "submitted" );
		if ( $filter->{'stop_found'} eq 'TRUE' ) {
			$filter->{'enabled'} = 'FALSE';
			my $qh =
			  $dbh->prepare(
				q( UPDATE filters SET enabled='FALSE' WHERE title=? ));
			$qh->execute( $filter->{'title'} );
		}
		return 1;
	}
	else {
		JdlBot::DownloadHistory::storeEntry( $links, $filter, $tv_episode, "failed to submit" );
		error( "... failed.", 1 );
		return 0;
	}
}
1;
