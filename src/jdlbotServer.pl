#!/usr/bin/env perl

use strict;
use warnings;

use EV;
use AnyEvent::Impl::EV;
use AnyEvent::HTTPD;
use Net::SSLeay;
use AnyEvent::HTTP;

use PAR;

use Error qw(:try);

use Data::Dumper;

use Path::Class;
use File::Path qw(make_path remove_tree);
use Text::Template;
use XML::FeedPP;
use Web::Scraper;
use LWP::Protocol::https;
use LWP::Simple qw($ua get);
use JSON::XS;
use URI::Escape;
use Getopt::Long;
use Perl::Version;
use DBI;
use DBIx::MultiStatementDo;
use Log::Message::Simple qw(msg error);

use JdlBot::Feed;
use JdlBot::UA;
use JdlBot::DownloadHistory;

# Set the UserAgent for external async requests.  Don't want to get flagged, do we?
$AnyEvent::HTTP::USERAGENT = JdlBot::UA::getAgent();


# Timeout for synchronous web requests
#  Usually this is only used to talk to the JD web interface
$ua->timeout(5);
# Set the useragent to the same string as the Async HTTP module
$ua->agent(JdlBot::UA::getAgent());
$ua->ssl_opts( verify_hostname => 0 );

# Declare globals... I know tisk tisk
my($dbh, %config, $watchers, %templates, $static, %assets);

# Encapsulate configuration code
{
	my $port;
	my $directory = "";
	my $configdir = "";
	my $configfile = "";
	my $versionFlag;
	
	my $version = Perl::Version->new("0.5.2");
	
	# Command line startup options
	#  Usage: jdlbotServer(.exe) [-d|--directory=dir] [-p|--port=port#] [-c|--configdir=dir] [-v|--version]
	GetOptions("port=i" => \$port, # Port for the local web server to run on
			   "directory=s" => \$directory, # Directory to change to after starting (for dev mostly)
			   "configdir=s" => \$configdir, # Where your config files are located
			   "version" => \$versionFlag); # Get the version number
	
	if( $versionFlag ){
		print STDOUT "jDlBot! version $version\n";
		exit(0);
	}
	
	if( $directory ){
		chdir($directory);
	}

	my @build_imports = qw(loadTemplates loadStatic loadAssets checkConfigFile openBrowser);
	if( PAR::read_file('build.txt') ){
		if( $^O eq 'darwin' ) {
			require JdlBot::Build::Mac; 
			import JdlBot::Build::Mac @build_imports;
		} elsif( $^O =~ /MSWin/ ){
			require JdlBot::Build::Win;
			import JdlBot::Build::Win @build_imports;
		}
	} else {
		use JdlBot::Build::Perl;
	}

	my $configFile = checkConfigFile();
	unless ( $configFile ){
		die "Could not find config file.\n";
	}	

	$dbh = DBI->connect("dbi:SQLite:dbname=$configFile","","") or
		die "Could not open config file.\n";
	%config = fetchConfig();
	
	#if (! $config{'version'}){ $config{'version'} = "0.1.0"; }
	my $dbVersion = Perl::Version->new($config{'version'});
	if ( $version->numify > $dbVersion->numify ){
		print STDOUT "Updating config...\n";

		require JdlBot::DbUpdate;
		JdlBot::DbUpdate::update($dbVersion, $dbh);

		print STDOUT "Update successful.\n";
		%config = fetchConfig();
	}

	# Port setting from the command line is temporary
	if( $port ){
		$config{'port'} = $port;
	}
}

%templates = loadTemplates();
$static = loadStatic();
%assets = loadAssets();

sub fetchConfig {
	my $configArrayRef = $dbh->selectall_arrayref( q( SELECT param, value FROM config ) )
		or die "Can't fetch configuration\n";
	
	my %tempConfig = ();
	foreach my $cfgParam (@$configArrayRef){
		$tempConfig{$$cfgParam[0]} = $$cfgParam[1];
	}
	
	return %tempConfig;
}

# Feed watchers
$watchers = {};
sub addWatcher {
	my ($url, $protocol, $interval, $follow_links , $filesize_pattern) = @_;

	$watchers->{$url} = AnyEvent->timer(
										after		=>	5,
										interval	=>	$interval * 60,
										cb			=>	sub {
											msg("Running watcher: " . $url, 1);

											my $qh = $dbh->prepare(q( SELECT * FROM filters WHERE enabled='TRUE' AND feeds LIKE ? ));
											$qh->execute('%"' . $url . '"%');
											my $filters = $qh->fetchall_hashref('title');

											if ( $qh->errstr || scalar keys %{ $filters } < 1 ){ return; }
											http_get( $protocol . $url , sub {
													my ($body, $hdr) = @_;

													if ($hdr->{Status} =~ /^2/) {
														JdlBot::Feed::scrape($url, $body, $filters, $follow_links, $filesize_pattern, $dbh, \%config);
													} else {
														error("HTTP error, $hdr->{Status} $hdr->{Reason}\n" .
																	"\tFailed to retrieve feed: $url", 1);
													}
												});
										});
	return 1;
}

{
	my $feeds = $dbh->selectall_arrayref(q( SELECT url, protocol, interval, follow_links, filesize_pattern FROM feeds WHERE enabled='TRUE' ));
	foreach my $feed (@{$feeds}){
		addWatcher(@{$feed});
	}
}

sub removeWatcher {
	my $url = shift;

	delete($watchers->{$url});

	return 1;
}

sub getNavigation {
	my ($url, $siteMap, $siteMapOrder) = @_;
	my $nav = "";
	foreach my $path (sort { $siteMapOrder->{$a} <=> $siteMapOrder->{$b} } keys %$siteMap) {
		if( $url eq $path ) {
			$nav .= "<li class='active'><a href='$path'>$siteMap->{$path}</a></li>";
		} else {
			$nav .= "<li><a href='$path'>$siteMap->{$path}</a></li>";
		}
	}
	return $nav;
}

my %siteMap = (
	'/' =>'Status',
	'/feeds' => 'Feeds',
	'/linktypes' => 'Link Types',
	'/filters' => 'Filters',
	'/history' => 'History',
	'/config' => '<span class="glyphicon glyphicon-cog" aria-hidden="true"></span> Configuration',
	'/help' => '<span class="glyphicon glyphicon-question-sign" aria-hidden="true"></span> Help',
);

my %siteMapOrder = (
	'/' => 0,
	'/feeds' => 1,
	'/linktypes' => 2,
	'/filters' => 3,
	'/history' => 4,
	'/config' => 5,
	'/help' => 6,
);

my $httpd = AnyEvent::HTTPD->new (host => $config{'host'}, port => $config{'port'});
msg("Server running on port: $config{'port'}\n" .
	"Open http://127.0.0.1:$config{'port'}/ in your favorite web browser to continue.\n",1);
	
	if( $config{'open_browser'} eq 'TRUE' ){openBrowser(%config);}

$httpd->reg_cb (
	'/' => sub {
		my ($httpd, $req) = @_;

		my $status;

		if ( get("http://$config{'jd_address'}:$config{'jd_port'}/flash") ){
			$status = 1
		} else {
			$status = 0;
		}

		my $statusHtml = $templates{'status'}->fill_in(HASH => {'port' => $config{'port'},
																'jd_address' => $config{'jd_address'},
																'jd_port' => $config{'jd_port'},
																'version' => $config{'version'},
																'check_update' => $config{'check_update'} eq 'TRUE' ? 'true' : 'false',
																'status' => $status
																});
		my $navHtml = getNavigation($req->url,\%siteMap, \%siteMapOrder);

		$req->respond ({ content => ['text/html', $templates{'base'}->fill_in(HASH => {'title' => $siteMap{$req->url}, 'strippedTitle' => $siteMap{$req->url} =~ s/<span.*span> //r, 'navigation' => $navHtml, 'content' => $statusHtml}) ]});
	},
	'/config' => sub {
		my ($httpd, $req) = @_;
		if( $req->method() eq 'GET' ){
		
		
		my $configHtml = $templates{'config'}->fill_in(HASH => {'host' => $config{'host'},
																'port' => $config{'port'},
																'jd_address' => $config{'jd_address'},
																'jd_port' => $config{'jd_port'},
																'check_update' => $config{'check_update'} eq 'TRUE' ? 'checked="checked"' : '',
																'open_browser' => $config{'open_browser'} eq 'TRUE' ? 'checked="checked"' : ''
																});
		$req->respond ({ content => ['text/html', $templates{'base'}->fill_in(HASH => {'title' => $siteMap{$req->url}, 'strippedTitle' => $siteMap{$req->url} =~ s/<span.*span> //r, 'navigation' => getNavigation($req->url,\%siteMap, \%siteMapOrder), 'content' => $configHtml}) ]});
		} elsif ( $req->method() eq 'POST' ){
			if( $req->parm('action') eq 'update' ){
				my $configParams = decode_json(uri_unescape($req->parm('data')));
				my $qh = $dbh->prepare('UPDATE config SET value=? WHERE param=?');
				foreach my $param (%$configParams){
					$qh->execute($configParams->{$param}, $param);
					if ( $qh->errstr ){ last; }
				}
				
				my $status;
				if ( ! $qh->errstr ){
					%config = fetchConfig();
					$status = 'Success.';
				} else {
					$status = 'Could not update config.  Try reloading jdlbot.';
				}
				
				$req->respond ({ content => ['application/json',  '{ "status" : "' . $status  . '" }' ]});
			}
		}
	},
	'/feeds' => sub {
		my ($httpd, $req) = @_;
		if( $req->method() eq 'GET' ){
		
		$req->respond ({ content => ['text/html', $templates{'base'}->fill_in(HASH => {'title' => $siteMap{$req->url}, 'strippedTitle' => $siteMap{$req->url} =~ s/<span.*span> //r, 'navigation' => getNavigation($req->url,\%siteMap, \%siteMapOrder), 'content' => $static->{'feeds.html'}}) ]});
		} elsif ( $req->method() eq 'POST' ){
			my $return = {'status' => 'failure'};
			if( $req->parm('action') =~ /add|update|enable/){
				my $feedParams = decode_json(uri_unescape($req->parm('data')));
				$feedParams->{'protocol'} = $1 if $feedParams->{'url'} =~ /^(https?:\/\/)/i;
				$feedParams->{'url'} =~ s/^https?:\/\///i;
				if ( !$feedParams->{'protocol'} ) {
					$feedParams->{'protocol'}='http://';
				}
				my $feedData = get($feedParams->{'protocol'} . $feedParams->{'url'});
				if( $feedData ){
					my $rssFeed;
					my $parseError = 0;
					try {
						$rssFeed = XML::FeedPP->new($feedData);
					} catch Error with{
						$parseError = 1;
					};
					
					if( defined($rssFeed) && $parseError != 1){
						my $qh;
						if ( $req->parm('action') eq 'add' ){
							$qh = $dbh->prepare(q(INSERT INTO feeds VALUES ( ? , ? , ? , NULL, 'TRUE', ?, ? )));
							$qh->execute($feedParams->{'url'}, $feedParams->{'interval'}, $feedParams->{'follow_links'}, $feedParams->{'protocol'}, $feedParams->{'filesize_pattern'});
							
							if ( !$qh->errstr ){
								my $qh = $dbh->prepare('SELECT * FROM feeds WHERE url=?');
								$qh->execute($feedParams->{'url'});
								$feedParams = $qh->fetchrow_hashref();
							}
							
						} elsif ( $req->parm('action') =~ /update|enable/ ){
							my $old_url = $feedParams->{'old_url'};
							delete($feedParams->{'old_url'});
							my @fields = sort keys %$feedParams;
							my @values = @{$feedParams}{@fields};
							$qh = $dbh->prepare(sprintf('UPDATE feeds SET %s=? WHERE url=?', join("=?, ", @fields)));
							push(@values, $old_url);
							$feedParams->{'old_url'} = $old_url;
							$qh->execute(@values);
							
							if ( !$qh->errstr ){
								removeWatcher($feedParams->{'old_url'});
								
								$qh = $dbh->prepare('SELECT title, feeds FROM filters WHERE feeds LIKE ? ');
								$qh->execute('%"' . $feedParams->{'old_url'} . '"%');
								my $filters = $qh->fetchall_hashref('title');
									
								if ( !$qh->errstr ){
									$qh = $dbh->prepare('UPDATE filters SET feeds=? WHERE title=?');
									foreach my $filter ( keys %{$filters} ){
										my $feeds = decode_json($filters->{$filter}->{'feeds'});
										my $new_feeds = [];
										foreach my $feed ( @{$feeds} ){
											if ( $feed ne $feedParams->{'old_url'} ){
												push(@$new_feeds, $feed);
											} else {
												push(@$new_feeds, $feedParams->{'url'});
											}
										}
										$qh->execute(encode_json($new_feeds), $filter);
									}
								}
							}
							
							if ( $req->parm('action') eq 'enable' ){
								my $qh = $dbh->prepare('SELECT * FROM feeds WHERE url=?');
								$qh->execute($feedParams->{'old_url'});
								$feedParams = $qh->fetchrow_hashref();
							}

						}
							
						if(!$qh->errstr){
							unless ( $feedParams->{'enabled'} eq 'FALSE' ){
								addWatcher($feedParams->{'url'}, $feedParams->{'protocol'}, $feedParams->{'interval'}, $feedParams->{'follow_links'}, $feedParams->{'filesize_pattern'});
							}
							$return->{'status'} = 'Success.';
							$return->{'element'} = $feedParams;						
						} else {
							$return->{'status'} = "Could not save feed data, possibly a duplicate feed?";
						}
						
					} else {
						$return->{'status'} = "Did not parse properly as an RSS feed, check the url";
					}
				} else {
					$return->{'status'} = "Could not fetch RSS feed, check the url";
				}
			} elsif ( $req->parm('action') eq 'delete' ) {
				my $feedParams = decode_json(uri_unescape($req->parm('data')));
				$feedParams->{'uid'} =~ s/^http:\/\///i;
				
				$return->{'status'} = "Could not delete feed.  Incorrect url?";
				my $qh = $dbh->prepare('DELETE FROM feeds WHERE url=?');
				$qh->execute($feedParams->{'uid'});
				$qh = $dbh->prepare('SELECT title, feeds FROM filters WHERE feeds LIKE ? ');
				$qh->execute('%' . $feedParams->{'uid'} . '%');
				my $filters = $qh->fetchall_hashref('title');

				if ( !$qh->errstr ){
					$qh = $dbh->prepare('UPDATE filters SET feeds=? WHERE title=?');
					foreach my $filter ( keys %{$filters} ){
						my $feeds = decode_json($filters->{$filter}->{'feeds'});
						my $new_feeds = [];
						foreach my $feed ( @{$feeds} ){
							if ( $feed ne $feedParams->{'uid'} ){
								push(@$new_feeds, $feed);
							}
						}
						$qh->execute(encode_json($new_feeds), $filter);
					}
				}
					
				if(!$qh->errstr){
					removeWatcher($feedParams->{'uid'});
					$return->{'status'} = 'Success.';
					$return->{'element'} = $feedParams;						
				}
			} elsif ( $req->parm('action') eq 'list' ) {
				$return->{'status'} = "Could not get list of feeds, possible database error.";
				my $feeds = $dbh->selectall_hashref(q( SELECT * FROM feeds ORDER BY url ), 'url');
				# Hashref fucks up the sorting
				my $count = 0;
				foreach my $key ( sort keys %{$feeds} ){
					$return->{'list'}[$count] = $feeds->{$key};
					$count++;
				}

				if ( !$dbh->errstr ){
					$return->{'status'} = "Success.";
				}
			}
			$return = encode_json($return);
			$req->respond ({ content => ['application/json',  $return ]});
		}
	},
	'/linktypes' => sub{
		my ($httpd, $req) = @_;
		if( $req->method() eq 'GET' ){

		$req->respond ({ content => ['text/html', $templates{'base'}->fill_in(HASH => {'title' => $siteMap{$req->url}, 'strippedTitle' => $siteMap{$req->url} =~ s/<span.*span> //r, 'navigation' => getNavigation($req->url,\%siteMap, \%siteMapOrder), 'content' => $static->{'linktypes.html'}}) ]});

		} elsif ( $req->method() eq 'POST' ){
			my $return = {'status' => 'failure'};
			if( $req->parm('action') =~ /^(add|update|delete|list)$/ ){

				my $qh;
				if ( $req->parm('action') eq 'list' ){
					$return->{'status'} = "Could not fetch list of Link Types.";

					$return->{'list'} = $dbh->selectall_arrayref(q( SELECT * FROM linktypes ORDER BY priority ), { Slice => {} });
				} elsif ( $req->parm('action') eq 'update' ){
					my $linktypeParams = decode_json(uri_unescape($req->parm('data')));
					$return->{'status'} = "Could not update list of Link Types.";

					my @fields = sort keys %{$linktypeParams->[0]};
					$qh = $dbh->prepare(sprintf('UPDATE linktypes SET %s=? WHERE linkhost=?', join("=?, ", @fields)));

					foreach my $linktype (@{$linktypeParams}){
						my @values = @{$linktype}{@fields};
						push(@values, $linktype->{linkhost});
						$qh->execute(@values);
					}

				} elsif ( $req->parm('action') eq 'delete' ){
					my $linktypeParams = decode_json(uri_unescape($req->parm('data')));
					$return->{'status'} = "Could not delete Link Type.";

					$qh = $dbh->prepare('DELETE FROM linktypes WHERE linkhost=?');
					$qh->execute($linktypeParams->{'uid'});

				} elsif ( $req->parm('action') eq 'add' ){
					my $linktypeParams = decode_json(uri_unescape($req->parm('data')));
					$return->{'status'} = "Could not add Link Type.";

					my @fields = sort keys %$linktypeParams;
					my @values = @{$linktypeParams}{@fields};
					$qh = $dbh->prepare(sprintf('INSERT INTO linktypes (%s) VALUES (%s)', join(",", @fields), join(",", ("?")x@fields)));
					$qh->execute(@values);
					if ( ! $qh->errstr ){
						$qh = $dbh->prepare('SELECT * FROM linktypes WHERE linkhost=?');
						$qh->execute($linktypeParams->{'linkhost'});
						$return->{'element'} = $qh->fetchrow_hashref();
					}
				}

				if(!$dbh->errstr){
					$return->{'status'} = 'Success.';
				}
				
	
			}
			$return = encode_json($return);
			$req->respond ({ content => ['application/json',  $return ]});

		}
	},
	'/filters' => sub{
		my ($httpd, $req) = @_;
		if( $req->method() eq 'GET' ){

		$req->respond ({ content => ['text/html', $templates{'base'}->fill_in(HASH => {'title' => $siteMap{$req->url}, 'strippedTitle' => $siteMap{$req->url} =~ s/<span.*span> //r, 'navigation' => getNavigation($req->url,\%siteMap, \%siteMapOrder), 'content' => $static->{'filters.html'}}) ]});

		} elsif ( $req->method() eq 'POST' ){
			my $return = {'status' => 'failure'};
			if( $req->parm('action') =~ /^(add|update|delete|config|getconfig)$/ ){
				my $filterParams = decode_json($req->parm('data'));

				my $qh;
				if ( $req->parm('action') eq 'add' ){
					$return->{'status'} = "Could not save filter data, either a duplicate title or missing options";
					my @fields = sort keys %$filterParams;
					my @values = @{$filterParams}{@fields};
					$qh = $dbh->prepare(sprintf('INSERT INTO filters (%s) VALUES (%s)', join(",", @fields), join(",", ("?")x@fields)));
					$qh->execute(@values);
					if ( ! $qh->errstr ){
						$qh = $dbh->prepare('SELECT * FROM filters WHERE title=?');
						$qh->execute($filterParams->{'title'});
						$return->{'element'} = $qh->fetchrow_hashref();
					}

				} elsif ( $req->parm('action') eq 'update' ){
					$return->{'status'} = "Could not save filter data, either a duplicate title or missing options";
					my $old_title = $filterParams->{'old_title'};
					delete($filterParams->{'old_title'});
					my @fields = sort keys %$filterParams;
					my @values = @{$filterParams}{@fields};
					$qh = $dbh->prepare(sprintf('UPDATE filters SET %s=? WHERE title=?', join("=?, ", @fields)));
					push(@values, $old_title);
					$filterParams->{'old_title'} = $old_title;
					$qh->execute(@values);
					$return->{'element'} = $filterParams;

				} elsif ( $req->parm('action') eq 'delete' ){
					$return->{'status'} = "Could not delete filter.  Incorrect title?";
					$qh = $dbh->prepare('DELETE FROM filters WHERE title=?');
					$qh->execute($filterParams->{'uid'});
					$return->{'element'} = $filterParams;						

				} elsif ( $req->parm('action') eq 'getconfig' ){
					$return->{'status'} = "Could not fetch filter configuration.";

					$return->{'filter_conf'} = $dbh->selectall_arrayref(q( SELECT * FROM filters WHERE title LIKE '%\_config' ESCAPE '\' ORDER BY title ), { Slice => {} });

				}

				if(!$dbh->errstr){
					$return->{'status'} = 'Success.';
				}
				

			} elsif ( $req->parm('action') =~ /^(list)$/ ){
				$return->{'status'} = "Could not fetch list of filters.";

				$return->{'list'} = $dbh->selectall_arrayref(q( SELECT * FROM filters WHERE title NOT LIKE '%\_config' ESCAPE '\' ORDER BY title ), { Slice => {} });

				if(!$dbh->errstr){
					$return->{'status'} = 'Success.';
				}
			}
			$return = encode_json($return);
			$req->respond ({ content => ['application/json',  $return ]});
		}
	},
	'/history' => sub{
		my ($httpd, $req) = @_;
		if( $req->method() eq 'GET' ){
			$req->respond ({ content => ['text/html', $templates{'base'}->fill_in(HASH => {'title' => $siteMap{$req->url}, 'strippedTitle' => $siteMap{$req->url} =~ s/<span.*span> //r, 'navigation' => getNavigation($req->url,\%siteMap, \%siteMapOrder), 'content' => $static->{'history.html'}}) ]});
		} elsif ( $req->method() eq 'POST' ){
			my $return = {'status' => 'failure'};
			if( $req->parm('action') =~ /^(list|redownload|clear)$/ ){
				
				if ( $req->parm('action') eq 'list' ){
					$return->{'list'} = JdlBot::DownloadHistory::listEntries();
					$return->{'status'} = 'Success.';
					
				} elsif ( $req->parm('action') eq 'redownload' ) {
					my $filterParams = $req->parm('data');
					my $history = JdlBot::DownloadHistory::getEntry($filterParams);
					if ($history) {
						msg("Re-downloading:" . $history->{'title'} . " ...",1);
						if (JdlBot::LinkHandler::JD2::processLinks($history->{'urls'}, $history->{'filter'}, $history->{'episode'}, $dbh, \%config)) {
							$return->{'status'} = 'Success.';
						}
					}
				} elsif ( $req->parm('action') eq 'clear' ) {
					if (JdlBot::DownloadHistory::clearHistory()) {
						$return->{'status'} = 'Success.';
					}
				}
				
			}
			$return = encode_json($return);
			$req->respond ({ content => ['application/json',  $return ]});
		}
	},
	'/help' => sub{
		my ($httpd, $req) = @_;
		$req->respond ({ content => ['text/html', $templates{'base'}->fill_in(HASH => {'title' => $siteMap{$req->url}, 'strippedTitle' => $siteMap{$req->url} =~ s/<span.*span> //r, 'navigation' => getNavigation($req->url,\%siteMap, \%siteMapOrder), 'content' => $static->{'help.html'}}) ]});

	},
	'/log' => sub{
		my ($httpd, $req) = @_;
		if( $req->method() eq 'GET' ){
			$req->respond ({ content => ['text/html', Log::Message::Simple->stack_as_string() ]});
		} elsif ( $req->method() eq 'POST' ){
			my $return = {'status' => 'failure'};
			if( $req->parm('action') =~ /^(delete)$/ ){
				Log::Message::Simple->flush();
				msg("Log cleared.\n",1);
				$return->{'status'} = 'Success.';
			}
			$return = encode_json($return);
			$req->respond ({ content => ['application/json',  $return ]});
		}
	},
	%assets
);

$httpd->run; # making a AnyEvent condition variable would also work

