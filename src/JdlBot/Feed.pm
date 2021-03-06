
package JdlBot::Feed;

use strict;
use warnings;

use XML::FeedPP;
use Error qw(:try);
use AnyEvent::HTTP;
use List::MoreUtils qw(uniq);
use Log::Message::Simple qw(msg debug error);
use URI::Find;
use Digest::SHA qw(sha256_base64);
use Data::Dumper;

use JdlBot::UA;
use JdlBot::TV;
use JdlBot::LinkHandler::JD2;

$AnyEvent::HTTP::USERAGENT = JdlBot::UA::getAgent();

sub read_filesize {
	my ($input) = @_;
	$input =~ /([\d\.]*)\s*(\D*)?/;
	my $filesize = $1;
	my $unit     = $2;
	if ( $unit =~ /^k/i ) {
		$filesize *= 1024;
	}
	if ( $unit =~ /^m/i ) {
		$filesize *= 1024**2;
	}
	if ( $unit =~ /^g/i ) {
		$filesize *= 1024**3;
	}
	return $filesize;
}

sub replace_history {
	my ( $new_history, $url, $dbh ) = @_;
	$dbh->do(
		qq(
    DELETE FROM history
    WHERE feed like '$url'
		), undef, 'DONE'
	);
	my $sth = $dbh->prepare(q{ INSERT INTO history(digest,feed) VALUES (?,?) });
	foreach my $digest (@$new_history) {
		$sth->execute( $digest, $url );
	}
}

sub scrape {
	my ( $url, $feedData, $filters, $follow_links, $filesize_pattern, $dbh,
		$config )
		= @_;
	my $rss;
	my $parseError = 0;
	try {
		$rss = XML::FeedPP->new($feedData);
	}
	catch Error with {
		$parseError = 1;
	};

	if ($parseError) { error( "Error parsing Feed: " . $url, 1 ); return; }
	my $history =
		$dbh->selectall_hashref(
		qq( SELECT digest FROM history WHERE feed LIKE '$url' ), 'digest' );
	my @new_history;

	foreach my $item ( $rss->get_item() ) {
		my $digest = sha256_base64($item->title());
		if ( $history->{$digest} ) {
			push( @new_history, $digest );
			debug("Already in history, ignoring: $digest")
		} else {
			push( @new_history, $digest );
			debug("Parsing: $digest");
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
					} else {
						if (
							index( $item->title(), $filters->{$filter}->{'filter1'} ) >= 0 )
						{
							$match = 1;
						}
					}

					if ($match) {
						if ( $filesize_pattern && $filters->{$filter}->{'min_filesize'} ) {
							if ( $item->title() =~ /$filesize_pattern/i ) {
								my $filesize = read_filesize("$1$2");
								my $minsize =
									read_filesize( $filters->{$filter}->{'min_filesize'} );
								print "$filesize > $minsize\n";
								if ( $filesize < $minsize ) {
									next;
								}
							}
						}
						if ( $filters->{$filter}->{'tv'} eq 'TRUE' ) {
							my $item_title;
							if ( $item->{'yt:videoId'} ) {
								$item_title = $item->title() . " - " . $item->{'published'};
							} else {
								$item_title = $item->title();
							}
							$episodeID = JdlBot::TV::checkTvMatch( $item_title,
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
												if ( my @filtered_content = $body =~ m/$reFilter/s ) {
													$match = 1;

		# if the pattern contains parentheses groups, extract only the grouped parts
													if ($1) {
														$body = join( "", @filtered_content );
													}
												}
											} else {
												if (
													index( $body, $filters->{$filter}->{'filter2'} ) >=
													0 )
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
										} else {
											push(
												@{ $filters->{$filter}->{'matches'} },
												{
													'title'       => $item->title(),
													'content'     => $body,
													'new_tv_last' => $episodeID
												}
											);
										}
									} else {
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
		replace_history( \@new_history, $url, $dbh );
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

	my $linkhosts = $dbh->selectall_arrayref(
		"SELECT linkhost FROM linktypes WHERE enabled='TRUE' ORDER BY priority");

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
				if (
					$linkType =~ $regex
					&& (!$filter->{'link_filter'}
						|| $link =~ /$filter->{'link_filter'}/ )
					)
				{
					push( @$linksToProcess, $link );
				}
			}

			if ( scalar @$linksToProcess > 0 ) {
				@$linksToProcess = uniq(@$linksToProcess);
				my %filterConf = %$filter;
				delete( $filterConf{'matches'} );
				$filterConf{'match_title'} = $filter->{'matches'}->[$count]->{'title'};
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
							$linksToProcess, \%filterConf,
							$filter->{'matches'}->[$count]->{'new_tv_last'},
							$dbh, $config
						)
						)
					{
						push(
							@{ $filter->{'new_tv_last_done'} },
							$filter->{'matches'}->[$count]->{'new_tv_last'}
						);
						next CONTENT;
					} else {
						$linksToProcess = [];
					}
				} else {
					msg( "Sending links for filter: " . $filter->{'title'} . " ...", 1 );
					if (
						JdlBot::LinkHandler::JD2::processLinks(
							$linksToProcess, \%filterConf,
							$filter->{'matches'}->[$count]->{'new_tv_last'},
							$dbh, $config
						)
						)
					{
						if ( $filter->{'stop_found'} eq 'TRUE' ) {
							return 1;
						} else {
							next CONTENT;
						}
					} else {
						$linksToProcess = [];
					}
				}
			}
		}
	}
	if ( $filter->{'new_tv_last_done'} ) {
		JdlBot::TV::storeTvLast( $filter->{'new_tv_last_done'},
			$filter->{'title'}, $dbh );
	}
	return 0;
}

1;
