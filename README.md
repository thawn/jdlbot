# jDlBot!

jDlBot is an RSS feed and web scraper that finds and sends links to [jDownloader](http://www.jdownloader.org).

## Installation

### Mac & Windows

1.   Download an appropriate build from [here](https://github.com/thawn/jdlbot/releases/tag/0.1.4).
2.   Extract.
3.   Run.
4.   Point your browser at [127.0.0.1:10050](http://127.0.0.1:10050/) (do NOT use IE).

### Linux, other Unix OSes

1.  Make sure you have all the appropriate perl modules installed:

    Run `perl -MCPAN -e 'install EV AnyEvent::HTTP AnyEvent::HTTPD Error Path::Class File::Path Text::Template XML::FeedPP Web::Scraper JSON::XS Getopt::Long Perl::Version DBIx::MultiStatementDo List::MoreUtils Log::Message::Simple URI::Find'`
    
    or `ppm install EV AnyEvent-HTTP AnyEvent-HTTPD Error Path-Class File-Path Text-Template XML-FeedPP Web-Scraper JSON-XS Getopt-Long Perl-Version DBIx-MultiStatementDo List-MoreUtils Log-Message-Simple URI-Find` depending on your perl distribution.

2.  Clone the git repo: `git clone git://github.com/jdlbot/jdlbot.git`.

3.  cd into jdlbot/src:  `cd jdlbot/src`.

4.  Run it:  `perl jdlbotServer.pl`.

5.  Point your browser at [127.0.0.1:10050](http://127.0.0.1:10050/) (do NOT use IE).

If you have problems, please check the [wiki](http://github.com/jdlbot/jdlbot/wiki).

## Features

*   Support for RSS1, 2 and Atom feeds

*   Option to follow feed links and scrape the resulting pages for links

    This is handy for some feeds where links only appear in comments

*   Primary and secondary filters

*   Regex support for filters

*   Automatic TV episode recognition

    It should never download the same episode twice.  This works for S01E01 and /2010.10.30/ formats.

*   Auto-disable option after a successful filter addition

    For things you only want to get *once*

*   Filters can apply to multiple feeds

*   Filters can specify which types of links to retrieve

*   Global Link Type priority list

    Allows you to download from your preferred hosts consistently
    
*		Download history allows to re-add links to jDownloader (history is only stored in memory, not saved to disk)


## Todo

*   Implement my.jdownloader api
*   Implement option that filter2 cuts out only matching part of page.
*   Suggest something!

## Build instructions

If you want to build from source, you need to install these additional modules:
`cpan pp File::Copy::Recursive`
then run `perl buildit.pl`
enjoy.
