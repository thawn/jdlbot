
package JdlBot::Feed;

use strict;
use warnings;

use Data::Dumper;

use XML::FeedPP;
use Error qw(:try);
use AnyEvent::HTTP;
use List::MoreUtils qw(uniq);
use Log::Message::Simple qw(msg error);
use URI::Find;

use JdlBot::UA;
use JdlBot::TV;
use JdlBot::LinkHandler::JD2;

$AnyEvent::HTTP::USERAGENT = JdlBot::UA::getAgent();

sub scrape {
	my ( $url, $feedData, $filters, $follow_links, $dbh, $config ) = @_;
	my $rss;
	my $parseError = 0;
	try {
		$rss = XML::FeedPP->new($feedData);
	}
	catch Error with {
		$parseError = 1;
	};

	if ($parseError) { error( "Error parsing Feed: " . $url, 1 ); return; }

	foreach my $item ( $rss->get_item() ) {

		foreach my $filter ( keys %{$filters} ) {
			if ( $filters->{$filter}->{'enabled'} eq 'TRUE' ) {
				if ( !$filters->{$filter}->{'matches'} ) {
					$filters->{$filter}->{'matches'} = ();
				}
				my $match     = 0;
				my $episodeID = "";
				if ( $filters->{$filter}->{'regex1'} eq 'TRUE' ) {
					my $reFilter = $filters->{$filter}->{'filter1'};
					if ( $item->title() =~ /$reFilter/ ) {
						$match = 1;
					}
				}
				else {
					if ( index( $item->title(), $filters->{$filter}->{'filter1'} ) >= 0 )
					{
						$match = 1;
					}
				}

				if ($match) {
					if ( $filters->{$filter}->{'tv'} eq 'TRUE' ) {
						$episodeID = JdlBot::TV::checkTvMatch( $item->title(),
							$filters->{$filter}, $dbh );
						unless ($episodeID) {
							next;
						}
					}
					push(
						@{ $filters->{$filter}->{'matches'} },
						{
							'title'       => $item->title(),
							'content'     => $item->description() . " " . $item->link(),
							'new_tv_last' => $episodeID
						}
					);

					if ( $follow_links eq 'TRUE' ) {
						$filters->{$filter}->{'outstanding'} += 1;

						my $return_outstanding = sub {
							if ( $filters->{$filter}->{'outstanding'} == 0 ) {
								findLinks( $filters->{$filter}, $dbh, $config );
							}
						};

						http_get(
							$item->link(),
							sub {
								my ( $body, $hdr ) = @_;

								if ( $hdr->{Status} =~ /^2/ ) {
									if ( $filters->{$filter}->{'filter2'} ) {
										my $match = 0;
										if ( $filters->{$filter}->{'regex2'} eq 'TRUE' ) {
											my $reFilter = $filters->{$filter}->{'filter2'};
											if ( $body =~ m/$reFilter/ ) {
												$match = 1;
											}
										}
										else {
											if (
												index( $body, $filters->{$filter}->{'filter2'} ) >= 0 )
											{
												$match = 1;
											}
										}
										if ($match) {
											push(
												@{ $filters->{$filter}->{'matches'} },
												{
													'title'       => $item->title(),
													'content'     => $body,
													'new_tv_last' => $episodeID
												}
											);
										}
									}
									else {
										push(
											@{ $filters->{$filter}->{'matches'} },
											{
												'title'       => $item->title(),
												'content'     => $body,
												'new_tv_last' => $episodeID
											}
										);
									}
								}
								else {
									error(
										"HTTP error, $hdr->{Status} $hdr->{Reason}\n"
											. "\tFailed to follow link: "
											. $item->link()
											. " for feed: $url",
										1
									);
								}
								$filters->{$filter}->{'outstanding'} -= 1;
								$return_outstanding->();
							}
						);
					}
				}
			}
		}
	}

	if ( $follow_links eq 'TRUE' ) { return; }

	foreach my $filter ( keys %{$filters} ) {
		if ( $filters->{$filter}->{'enabled'} eq 'TRUE' ) {
			findLinks( $filters->{$filter}, $dbh, $config );
		}
	}

	return 0;
}

sub findLinks {
	my ( $filter, $dbh, $config ) = @_;

	my $linkhosts = [];
	if ( $filter->{'link_types'} ) {
		my $regex = $filter->{'link_types'};
		$linkhosts->[0] = $regex;
	}
	else {
		$linkhosts = $dbh->selectall_arrayref(
			"SELECT linkhost FROM linktypes WHERE enabled='TRUE' ORDER BY priority");
	}

CONTENT: foreach my $count ( 0 .. $#{ $filter->{'matches'} } ) {
		my @links;
		my $finder = URI::Find->new(
			sub {
				my ($uri) = shift;
				my $string;
				open( my $fh, '>', \$string );
				print $fh $uri;
				close $fh;
				push @links, $string;
			}
		);
		$finder->find( \$filter->{'matches'}->[$count]->{'content'} );

		my $prevLink;
		my $linksToProcess = [];
		keys @{$linkhosts};
		foreach my $linkhost ( @{$linkhosts} ) {
			my $regex = $linkhost->[0];
			$regex = qr/$regex/;
			keys @links;
			foreach my $link (@links) {
				my ($linkType) = ( $link =~ /^https?:\/\/([^\/]+)\// );
				if ( !$linkType ) { next; }

# If the link type is appropriate;
#   This needs to be replaced by a function that checks against a list of domains
				if ( $linkType =~ $regex ) {
					push( @$linksToProcess, $link );
				}
			}

			if ( scalar @$linksToProcess > 0 ) {
				@$linksToProcess = uniq(@$linksToProcess);
				my %filterConf=%$filter;
				delete($filterConf{'matches'});
				if ( $filter->{'tv'} eq 'TRUE' ) {
					unless ( $filter->{'new_tv_last_done'} ) {
						$filter->{'new_tv_last_done'} = [];
					}
					foreach my $tvhas ( @{ $filter->{'new_tv_last_done'} } ) {
						if ( $filter->{'matches'}->[$count]->{'new_tv_last'} eq $tvhas ) {
							next CONTENT;
						}
					}

					msg( "Sending links for filter: " . $filter->{'title'} . " ...", 1 );
					if (
						JdlBot::LinkHandler::JD2::processLinks(
							$linksToProcess,
							\%filterConf, $filter->{'matches'}->[$count]->{'new_tv_last'}, $dbh, $config
						)
						)
					{
						push(
							@{ $filter->{'new_tv_last_done'} },
							$filter->{'matches'}->[$count]->{'new_tv_last'}
						);
						next CONTENT;
					}
					else {
						$linksToProcess = [];
					}
				}
				else {
					msg( "Sending links for filter: " . $filter->{'title'} . " ...", 1 );
					if (
						JdlBot::LinkHandler::JD2::processLinks(
							$linksToProcess,
							\%filterConf, $filter->{'matches'}->[$count]->{'new_tv_last'}, $dbh, $config
						)
						)
					{
						if ( $filter->{'stop_found'} eq 'TRUE' ) {
							return 1;
						}
						else {
							next CONTENT;
						}
					}
					else {
						$linksToProcess = [];
					}
				}
			}
		}
	}
	if ($filter->{'new_tv_last_done'}) {
		JdlBot::TV::storeTvLast($filter->{'new_tv_last_done'},$filter->{'title'}, $dbh);
	}
	return 0;
}

1;
