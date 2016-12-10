
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
$ua->agent(JdlBot::UA::getAgent() );
$ua->default_header('Referer' => 'http://localhost:9666/flashgot');

#  Returns 1 for success, 0 for failure.
sub processLinks {
	my ( $links, $filter, $dbh, $config ) = @_;

	if ( $filter->{'enabled'} eq 'FALSE' ) { return 0; }

	JdlBot::DownloadHistory::storeEntry($links, $filter);
	
	my $jdInfo =
	  $config->{'jd_address'} . ":" . $config->{'jd_port'} . "/flashgot";
	my $jdStart = $filter->{'autostart'} eq 'TRUE' ? 1 : 0;

	my $c = get("http://$jdInfo");
	if ( !$c ) { error("... failed toconnect to jDownloader API interface.",1); return 0; }

	my $newlinks = join( "\r\n", @$links );
	my $response;
	#$newlinks = uri_escape($newlinks);
	if ($jdStart) {
		$response = $ua->post(
			"http://$jdInfo",
			[
				'source'    => 'http://localhost',
				'urls'      => $newlinks,
				'autostart' => 1
			]
		);
		
	}
	else {
		$response = $ua->post( "http://$jdInfo",
			[ 
				'source' => 'http://localhost',
				'urls' => $newlinks,
			]
		);
	}
	if ( $response->is_success  ){
		msg("... success.",1);
		if ( $filter->{'stop_found'} eq 'TRUE' ) {
			$filter->{'enabled'} = 'FALSE';
			my $qh =
			  $dbh->prepare(q( UPDATE filters SET enabled='FALSE' WHERE title=? ));
			$qh->execute( $filter->{'title'} );
		}
		return 1;
	} else {
		error("... failed.",1);
		return 0;
	}
}
1;
