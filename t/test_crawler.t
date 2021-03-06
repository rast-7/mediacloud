#!/usr/bin/env perl

use strict;
use warnings;

#
# Basic sanity test of crawler functionality
#
# ---
#
# If you run t/test_crawler.t with the -d command it rewrites the files. E.g.:
#
#     ./script/run_in_env.sh ./t/test_crawler.t  -d
#
# This changes the expected results so it's important to make sure that you're
# not masking bugs in the code. Also it's a good idea to manually examine the
# changes in t/data/crawler_stories.pl before committing them.
#

use Test::More tests => 233;
use Test::Differences;
use Test::Deep;

use Modern::Perl "2015";
use MediaWords::CommonLibs;

use Test::NoWarnings;

use MediaWords::Crawler::Engine;
use MediaWords::DBI::Downloads;
use MediaWords::DBI::DownloadTexts;
use MediaWords::DBI::Stories;
use MediaWords::DBI::Stories::Extract;
use MediaWords::StoryVectors;
use MediaWords::Test::Data;
use MediaWords::Test::DB;
use MediaWords::Test::LocalServer;
use MediaWords::Test::Text;
use MediaWords::Util::Config;
use MediaWords::Util::DateTime;
use MediaWords::Util::ParseHTML;

use Data::Dumper;
use Encode;
use Readonly;

# add a test media source and feed to the database
sub _add_test_feed($$$$)
{
    my ( $db, $url_to_crawl, $test_name, $test_prefix ) = @_;

    my $test_medium = $db->query(
        <<EOF,
        INSERT INTO media (name, url)
        VALUES (?, ?)
        RETURNING *
EOF
        '_ Crawler Test', $url_to_crawl
    )->hash;

    my $syndicated_feed = $db->create(
        'feeds',
        {
            media_id => $test_medium->{ media_id },
            name     => '_ Crawler Test - Syndicated Feed',
            url      => "$url_to_crawl/$test_prefix/test.rss"
        }
    );
    my $web_page_feed = $db->create(
        'feeds',
        {
            media_id => $test_medium->{ media_id },
            name     => '_ Crawler Test - Web Page Feed',
            url      => "$url_to_crawl/$test_prefix/home.html",
            type     => 'web_page'
        }
    );

    ok( $syndicated_feed->{ feeds_id }, "$test_name - test syndicated feed created" );
    ok( $web_page_feed->{ feeds_id },   "$test_name - test web page feed created" );

    return $syndicated_feed;
}

Readonly my $crawler_timeout => MediaWords::Util::Config::get_config->{ mediawords }->{ crawler_test_timeout };

# run the crawler for one minute, which should be enough time to gather all of
# the stories from the test feed and test-extract them
sub _run_crawler()
{
    my $crawler = MediaWords::Crawler::Engine->new();

    $crawler->test_mode( 1 );    # will set extract_in_process() too

    #$crawler->children_exit_on_kill( 1 );

    $| = 1;

    $crawler->crawl();
}

sub _get_db_module_tags($$$)
{
    my ( $db, $story, $module ) = @_;

    my $tag_set = $db->find_or_create( 'tag_sets', { name => $module } );

    return $db->query(
        <<"EOF",
        SELECT t.tags_id AS tags_id,
               t.tag_sets_id AS tag_sets_id,
               t.tag AS tag
        FROM stories_tags_map AS stm,
             tags AS t,
             tag_sets AS ts
        WHERE stm.stories_id = ?
              AND stm.tags_id = t.tags_id
              AND t.tag_sets_id = ts.tag_sets_id
              AND ts.name = ?
EOF
        $story->{ stories_id },
        $module
    )->hashes;
}

sub _fetch_content($$)
{
    my ( $db, $story ) = @_;

    my $download = $db->query(
        <<"EOF",
        SELECT *
        FROM downloads
        WHERE stories_id = ?
        order by downloads_id
EOF
        $story->{ stories_id }
    )->hash;

    return $download ? MediaWords::DBI::Downloads::fetch_content( $db, $download ) : '';
}

# get stories from database, including content, text, tags, and sentences
sub _get_expanded_stories($)
{
    my ( $db ) = @_;

    my $stories = $db->query(
        <<EOF
        SELECT s.*,
               f.type AS feed_type
        FROM stories s,
             feeds_stories_map fsm,
             feeds f
        WHERE s.stories_id = fsm.stories_id
          AND fsm.feeds_id = f.feeds_id
EOF
    )->hashes;

    for my $story ( @{ $stories } )
    {
        $story->{ content } = _fetch_content( $db, $story );
        $story->{ extracted_text } = MediaWords::DBI::Stories::Extract::get_text_for_word_counts( $db, $story );
        $story->{ tags } = _get_db_module_tags( $db, $story, 'NYTTopics' );

        $story->{ story_sentences } = $db->query(
            <<EOF,
            SELECT *
            FROM story_sentences
            WHERE stories_id = ?
            ORDER BY stories_id,
                     sentence_number
EOF
            $story->{ stories_id }
        )->hashes;

    }

    return $stories;
}

sub _purge_story_sentences_id_field($)
{
    my ( $sentences ) = @_;

    for my $sentence ( @$sentences )
    {
        $sentence->{ story_sentences_id } = '';
        delete $sentence->{ story_sentences_id };
    }
}

# replace all stories_id fields with the normalized url of the corresponding story
# within the stories data structure
sub _replace_stories_ids_with_urls($)
{
    my ( $stories ) = @_;

    my $story_urls = {};
    for my $story ( @{ $stories } )
    {
        my $url = $story->{ url };
        $url =~ s~https?://[^/]*~~;
        $story_urls->{ $story->{ stories_id } } = $url;
    }

    my $stack = [ @{ $stories } ];
    while ( @{ $stack } )
    {
        my $o = pop( @{ $stack } );

        if ( ref( $o ) eq 'HASH' )
        {
            if ( $o->{ stories_id } )
            {
                $o->{ stories_id } = $story_urls->{ $o->{ stories_id } };
            }

            push( @{ $stack }, values( %{ $o } ) );
        }
        elsif ( ref( $o ) eq 'ARRAY' )
        {
            push( @{ $stack }, @{ $o } );
        }
    }
}

# test various results of the crawler
sub _test_stories($$$$)
{
    my ( $db, $test_name, $test_prefix, $stories_count ) = @_;

    my $download_errors = $db->query( "select * from downloads where state = 'error'" )->hashes;
    is( scalar( @{ $download_errors } ), 0, "$test_name - download errors" );
    die( "errors: " . Dumper( $download_errors ) ) if ( scalar @{ $download_errors } );

    my $stories = _get_expanded_stories( $db );

    is( scalar @{ $stories }, $stories_count, "$test_name - story count" );

    my $test_stories = MediaWords::Test::Data::fetch_test_data_from_individual_files( "crawler_stories/$test_prefix" );

    $test_stories = MediaWords::Test::Data::adjust_test_timezone( $test_stories, $test_stories->[ 0 ]->{ timezone } );

    # replace stories_id with urls so that the order of stories
    # doesn't matter
    _replace_stories_ids_with_urls( $stories );
    _replace_stories_ids_with_urls( $test_stories );

    my $test_story_hash;
    map { $test_story_hash->{ $_->{ title } } = $_ } @{ $test_stories };

    for my $story ( @{ $stories } )
    {
        my $story_url = $story->{ url };

        my $test_story = $test_story_hash->{ $story->{ title } };
        if ( ok( $test_story, "$test_name ($story_url) - story match: " . $story->{ title } ) )
        {
            my $fields = [ qw(description extracted_text) ];

            # can't test web_page story dates against historical data b/c they are supposed to have
            # the current date
            push( @{ $fields }, qw(publish_date guid) ) unless ( $story->{ feed_type } eq 'web_page' );

            for my $field ( @{ $fields } )
            {
                oldstyle_diff;

              TODO:
                {
                    my $fake_var;    #silence warnings
                     #eq_or_diff( $story->{ $field }, encode_utf8($test_story->{ $field }), "story $field match" , {context => 0});
                    MediaWords::Test::Text::eq_or_sentence_diff(
                        $story->{ $field },
                        $test_story->{ $field },
                        "$test_name ($story_url) - story $field match"
                    );
                }
            }

            MediaWords::Test::Text::eq_or_sentence_diff(
                $story->{ content },
                $test_story->{ content },
                "$test_name ($story_url) - story content matches"
            );

            is(
                scalar( @{ $story->{ tags } } ),
                scalar( @{ $test_story->{ tags } } ),
                "$test_name ($story_url) - story tags count"
            );

            my $expected_sentences = join( "\n", map { $_->{ sentence } } @{ $test_story->{ story_sentences } } );
            my $got_sentences      = join( "\n", map { $_->{ sentence } } @{ $story->{ story_sentences } } );
            eq_or_diff( $expected_sentences, $got_sentences, "$test_name ($story_url) - sentences match" );

            _purge_story_sentences_id_field( $story->{ story_sentences } );
            _purge_story_sentences_id_field( $test_story->{ story_sentences } );

            # as above, don't compare dates for web_page stories
            if ( $story->{ feed_type } eq 'web_page' )
            {
                map { delete( $_->{ publish_date } ) }
                  ( @{ $story->{ story_sentences } }, @{ $test_story->{ story_sentences } } );
            }

            $test_story->{ story_sentences } =
              MediaWords::Test::Data::adjust_test_timezone( $test_story->{ story_sentences }, $test_story->{ timezone } );

            cmp_deeply(
                $story->{ story_sentences },
                $test_story->{ story_sentences },
                "$test_name ($story_url) - story sentences " . $story->{ stories_id }
            );

        }

        delete( $test_story_hash->{ $story->{ title } } );
    }
}

# simple test to verify that each story has at least 60 characters in its sentences
sub _sanity_test_stories($$$)
{
    my ( $stories, $test_name, $test_prefix ) = @_;

    for my $story ( @{ $stories } )
    {
        next if ( $story->{ title } =~ /inline/ );    # expect inline stories to be short
        my $all_sentences = join( '. ', map { $_->{ sentence } } @{ $story->{ story_sentences } } );
        ok( length( $all_sentences ) >= 80,
            "$test_name - story '$story->{ url }' has at least 80 characters in its sentences" );
    }
}

# store the stories as test data to compare against in subsequent runs
sub _dump_stories($$$)
{
    my ( $db, $test_name, $test_prefix ) = @_;

    my $stories = _get_expanded_stories( $db );

    my $tz = MediaWords::Util::DateTime::local_timezone()->name;

    map { $_->{ timezone } = $tz } @{ $stories };

    MediaWords::Test::Data::store_test_data_to_individual_files( "crawler_stories/$test_prefix", $stories );

    _sanity_test_stories( $stories, $test_name, $test_prefix );
}

sub _test_crawler($$$)
{
    my ( $test_name, $test_prefix, $stories_count ) = @_;

    MediaWords::Test::DB::test_on_test_database(
        sub {
            my ( $db ) = @_;

            my $crawler_data_location = MediaWords::Test::Data::get_path_to_data_files( 'crawler' );

            my $test_http_server = MediaWords::Test::LocalServer->new( $crawler_data_location );
            $test_http_server->start();
            my $url_to_crawl = $test_http_server->url();

            INFO "Adding test feed...";
            _add_test_feed( $db, $url_to_crawl, $test_name, $test_prefix );

            INFO "Starting crawler...";
            _run_crawler();

            if ( defined( $ARGV[ 0 ] ) && ( $ARGV[ 0 ] eq '-d' ) )
            {
                INFO "Dumping stories...";
                _dump_stories( $db, $test_name, $test_prefix );
            }

            INFO "Testing stories...";
            _test_stories( $db, $test_name, $test_prefix, $stories_count );

            INFO "Killing server";
            $test_http_server->stop();
        }
    );
}

sub main
{
    # Errors might want to print out UTF-8 characters
    binmode( STDERR, ':utf8' );
    binmode( STDOUT, ':utf8' );
    my $builder = Test::More->builder;

    binmode $builder->output,         ":utf8";
    binmode $builder->failure_output, ":utf8";
    binmode $builder->todo_output,    ":utf8";

    # Test short inline "content:..." downloads
    _test_crawler( 'Short "inline" downloads', 'inline_content', 4 );

    # Test Global Voices downloads
    _test_crawler( 'Global Voices', 'gv', 16 );

    # Test multilanguage downloads
    _test_crawler(
        'Multilanguage downloads',
        'multilanguage',
        6 - 1,    # there are 6 tests, but one of them is an empty page
    );

    Test::NoWarnings::had_no_warnings();
}

main();
