package MediaWords::Languages::ru;

use strict;
use warnings;

use base 'MediaWords::Languages::Language::PythonWrapper';

use Modern::Perl "2015";
use MediaWords::CommonLibs;

sub _python_language_class_path
{
    return 'mediawords.languages.ru';
}

sub _python_language_class_name
{
    return 'RussianLanguage';
}

1;
