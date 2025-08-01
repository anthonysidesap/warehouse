# SPDX-License-Identifier: Apache-2.0

from opensearchpy import Date, Document, Keyword, Text, analyzer

from warehouse.search.utils import doc_type

EmailAnalyzer = analyzer(
    "email",
    tokenizer="uax_url_email",
    filter=["lowercase", "stop", "snowball"],
)

NameAnalyzer = analyzer(
    "normalized_name",
    tokenizer="lowercase",
    filter=["lowercase", "word_delimiter"],
)


@doc_type
class Project(Document):
    name = Text()
    normalized_name = Text(analyzer=NameAnalyzer)
    summary = Text(analyzer="snowball")
    description = Text(analyzer="snowball")
    author = Text()
    author_email = Text(analyzer=EmailAnalyzer)
    maintainer = Text()
    maintainer_email = Text(analyzer=EmailAnalyzer)
    license = Text()
    home_page = Keyword()
    download_url = Keyword()
    keywords = Text(analyzer="snowball")
    platform = Keyword()
    created = Date()
    classifiers = Keyword(multi=True)

    @classmethod
    def from_db(cls, release):
        obj = cls(meta={"id": release.normalized_name})
        obj["name"] = release.name
        obj["normalized_name"] = release.normalized_name
        obj["summary"] = release.summary
        obj["description"] = release.description[:5_000_000]
        obj["author"] = release.author
        obj["author_email"] = release.author_email
        obj["maintainer"] = release.maintainer
        obj["maintainer_email"] = release.maintainer_email
        obj["home_page"] = release.home_page
        obj["download_url"] = release.download_url
        obj["keywords"] = release.keywords
        obj["platform"] = release.platform
        obj["created"] = release.created
        obj["classifiers"] = release.classifiers

        return obj

    class Index:
        # make sure this class can match any index so it will always be used to
        # deserialize data coming from opensearch.
        name = "*"
