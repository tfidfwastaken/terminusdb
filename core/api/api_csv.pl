:- module(api_csv, [csv_load/6,csv_update/6,csv_dump/5]).
:- use_module(core(util)).
:- use_module(core(query)).
:- use_module(core(transaction)).
:- use_module(core(triple)).
:- use_module(core(account)).
:- use_module(library(terminus_store)).

csv_load(System_DB, Auth, Path, Commit_Info, Files, Options) :-

    do_or_die(
        resolve_absolute_string_descriptor_and_default_graph(Path, Descriptor, Graph),
        error(invalid_graph_descriptor(Path),_)),

    askable_settings_context(
        Descriptor,
        _{ system : System_DB,
           authorization : Auth,
           commit_info: Commit_Info,
           files : Files,
           filter : type_name_filter{ type: (Graph.type),
                                      names : [Graph.name]}},
        Context),

    assert_write_access(Context),

    csv_load_into_context(Files,Context,Options).

csv_load_into_context(Files, Context, Options) :-

    default_options(Options, Default_Options),

    with_transaction(
        Context,
        (   query_default_write_graph(Context, Read_Write_Obj),
            read_write_obj_builder(Read_Write_Obj, Builder),
            forall(
                member(Name=Path, Files),
                csv_builder(Name, Path, Builder, Default_Options)
            )
        ),
        _).

csv_update(System_DB, Auth, Path, Commit_Info, Files, Options) :-

    do_or_die(
        resolve_absolute_string_descriptor_and_default_graph(Path, Descriptor, Graph),
        error(invalid_graph_descriptor(Path),_)),

    askable_settings_context(
        Descriptor,
        _{ system : System_DB,
           authorization : Auth,
           files : Files,
           commit_info: Commit_Info,
           filter : type_name_filter{ type: (Graph.type),
                                      names : [Graph.name]}},
        Context),

    assert_write_access(Context),

    csv_update_into_context(Files,Context,Options).

csv_update_into_context(Files, Context, Options) :-
    default_options(Options, Default_Options),

    open_memory_store(Store),
    open_write(Store, Builder),

    forall(
        member(Name=Path, Files),
        csv_builder(Name, Path, Builder, Default_Options)
    ),
    nb_commit(Builder, Layer),

    with_transaction(
        Context,
        (   query_default_write_graph(Context, Read_Write_Obj),
            read_write_obj_builder(Read_Write_Obj, CSV_Builder),
            nb_apply_diff(CSV_Builder,Layer)
        ),
        _).

csv_dump(System_DB, Auth, Path, [Name=Filename], Options) :-

    do_or_die(
        resolve_absolute_string_descriptor_and_default_graph(Path, Descriptor, Graph),
        error(invalid_graph_descriptor(Path),_)),

    default_options(Options, Default_Options),

    askable_settings_context(
        Descriptor,
        _{ system : System_DB,
           authorization : Auth,
           filter : type_name_filter{ type: (Graph.type),
                                      names : [Graph.name]}},
        Pre_Context),
    % Set up csv prefix
    get_dict(prefixes, Pre_Context, Prefixes),
    option(schema_prefix(Schema_Prefix), Default_Options),

    New_Prefixes = (Prefixes.put(_{ csv: Schema_Prefix })),
    Context = (Pre_Context.put(_{ prefixes : New_Prefixes})),

    tmp_file_stream(Filename, Stream, [encoding(utf8)]),

    csv_columns(Name, Context, Columns),
    % collect header predicates

    % write headers
    maplist([_-Name-_,Name]>>true,Columns,Column_Names),
    Header =.. [row|Column_Names],
    csv_write_stream(Stream, [Header], []),

    % write rows
    forall(
        (   ask(Context,
                (   t(CSV, rdfs:label, Name^^_),
                    t(CSV, csv:row, Row)
                )),

            findall(RowDatum,
                    (   member(Predicate-_-_, Columns),

                        ask(Context,
                            t(Row, Predicate, RowDatumTyped)),
                        RowDatum^^_ = RowDatumTyped
                    ),
                    RowData),
            RowValue =.. [row|RowData]),
        csv_write_stream(Stream, [RowValue], [])
    ),

    close(Stream).

csv_columns(Name, Context, Sorted_Columns) :-
    get_dict(prefixes, Context, Prefixes),

    findall(Predicate-Column_Name-Column_Index,
            (   ask(Context,
                    (   t(CSV, rdfs:label, Name^^_),
                        t(CSV, csv:column, ColumnObject),
                        t(ColumnObject, csv:column_name, Column_Name^^_),
                        t(ColumnObject, csv:index, Column_Index^^_)
                    )),
                uri_encoded(query_value, Column_Name, Column_Encoded),
                atomic_list_concat([column_, Column_Encoded], Col),
                prefixed_to_uri(csv:Col, Prefixes, Predicate)
            ),
            Columns),

    predsort([Cmp,_-_-O,_-_-I]>>compare(Cmp,O,I), Columns, Sorted_Columns).


default_options(Options, Default_Options) :-
    (   option(data_prefix(_), Options)
    ->  Options_1 = Options
    ;   Data_Prefix = 'csv:///data/',
        merge_options(Options, [data_prefix(Data_Prefix)], Options_1)),

    (   option(schema_prefix(_), Options_1)
    ->  Default_Options = Options_1
    ;   Schema_Prefix = 'csv:///schema#',
        merge_options(Options_1, [schema_prefix(Schema_Prefix)], Default_Options)).


:- begin_tests(csv_api).

:- use_module(core(util/test_utils)).
:- use_module(core(query)).
:- use_module(core(triple)).
:- use_module(core(transaction)).


test(csv_load,
     [setup((setup_temp_store(State),
             create_db_without_schema("admin", "testdb")
            )),
      cleanup(teardown_temp_store(State))]
    ) :-

    tmp_file_stream(Filename, Stream, [encoding(utf8)]),
    format(Stream, "some,header~n", []),
    format(Stream, "1,2~n", []),
    format(Stream, "3,4~n", []),
    close(Stream),

    Path = 'admin/testdb',
    Files = ['csv'=Filename],
    Commit_Info = _{ author : "me", message : "a message"},
    open_descriptor(system_descriptor{}, System_DB),
    super_user_authority(Auth),

    csv_load(System_DB, Auth, Path, Commit_Info, Files, []),

    resolve_absolute_string_descriptor(Path, Desc),

    findall(X-Y-Z, ask(Desc,t(X, Y, Z)), Triples),
    Triples = [
        'csv:///data/ColumnObject_csv_header'-'csv:///schema#column_name'-("header"^^xsd:string),
        'csv:///data/ColumnObject_csv_header'-'csv:///schema#index'-(1^^xsd:integer),
        'csv:///data/ColumnObject_csv_header'-(rdf:type)-'csv:///schema#Column',
        'csv:///data/ColumnObject_csv_some'-'csv:///schema#column_name'-("some"^^xsd:string),
        'csv:///data/ColumnObject_csv_some'-'csv:///schema#index'-(0^^xsd:integer),
        'csv:///data/ColumnObject_csv_some'-(rdf:type)-'csv:///schema#Column',
        'csv:///data/csv'-'csv:///schema#column'-'csv:///data/ColumnObject_csv_header','csv:///data/csv'-'csv:///schema#column'-'csv:///data/ColumnObject_csv_some',
        'csv:///data/csv'-'csv:///schema#row'-'csv:///data/row7b52009b64fd0a2a49e6d8a939753077792b0554',
        'csv:///data/csv'-'csv:///schema#row'-'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59',
        'csv:///data/csv'-(rdf:type)-'csv:///schema#Csv',
        'csv:///data/csv'-(rdfs:label)-("csv"^^xsd:string),
        'csv:///data/row7b52009b64fd0a2a49e6d8a939753077792b0554'-'csv:///schema#column_header'-("2"^^xsd:string),
        'csv:///data/row7b52009b64fd0a2a49e6d8a939753077792b0554'-'csv:///schema#column_some'-("1"^^xsd:string),
        'csv:///data/row7b52009b64fd0a2a49e6d8a939753077792b0554'-(rdf:type)-'csv:///schema#Row_c40ce0246f480cd2baca44a7477fee98662917b7',
        'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59'-'csv:///schema#column_header'-("4"^^xsd:string),
        'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59'-'csv:///schema#column_some'-("3"^^xsd:string),
        'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59'-(rdf:type)-'csv:///schema#Row_c40ce0246f480cd2baca44a7477fee98662917b7'
    ].

test(csv_update,
     [setup((setup_temp_store(State),
             create_db_without_schema("admin", "testdb")
            )),
      cleanup(teardown_temp_store(State))]
    ) :-

    tmp_file_stream(Filename, Stream, [encoding(utf8)]),
    format(Stream, "some,header~n", []),
    format(Stream, "1,2~n", []),
    format(Stream, "3,4~n", []),
    close(Stream),

    Path = 'admin/testdb',
    Files = ['csv'=Filename],
    Commit_Info = _{ author : "me", message : "a message"},
    open_descriptor(system_descriptor{}, System_DB),
    super_user_authority(Auth),
    csv_load(System_DB, Auth, Path, Commit_Info, Files, []),

    tmp_file_stream(Filename2, Stream2, [encoding(utf8)]),
    format(Stream2, "some,header~n", []),
    format(Stream2, "1,9~n", []),
    format(Stream2, "3,4~n", []),
    close(Stream2),

    Files2 = ['csv'=Filename2],
    open_descriptor(system_descriptor{}, System_DB2),
    csv_update(System_DB2, Auth, Path, Commit_Info, Files2, []),

    resolve_absolute_string_descriptor(Path, Desc),
    findall(X-Y-Z, ask(Desc,t(X, Y, Z)), Triples),
    Triples = [
        'csv:///data/ColumnObject_csv_header'-'csv:///schema#column_name'-("header"^^xsd:string),
        'csv:///data/ColumnObject_csv_header'-'csv:///schema#index'-(1^^xsd:integer),
        'csv:///data/ColumnObject_csv_header'-(rdf:type)-'csv:///schema#Column',
        'csv:///data/ColumnObject_csv_some'-'csv:///schema#column_name'-("some"^^xsd:string),
        'csv:///data/ColumnObject_csv_some'-'csv:///schema#index'-(0^^xsd:integer),
        'csv:///data/ColumnObject_csv_some'-(rdf:type)-'csv:///schema#Column',
        'csv:///data/csv'-'csv:///schema#column'-'csv:///data/ColumnObject_csv_header',
        'csv:///data/csv'-'csv:///schema#column'-'csv:///data/ColumnObject_csv_some',
        'csv:///data/csv'-'csv:///schema#row'-'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59',
        'csv:///data/csv'-'csv:///schema#row'-'csv:///data/rowb3f0c7f6bb763af1be91d9e74eabfeb199dc1f1f',
        'csv:///data/csv'-(rdf:type)-'csv:///schema#Csv',
        'csv:///data/csv'-(rdfs:label)-("csv"^^xsd:string),
        'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59'-'csv:///schema#column_header'-("4"^^xsd:string),
        'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59'-'csv:///schema#column_some'-("3"^^xsd:string),
        'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59'-(rdf:type)-'csv:///schema#Row_c40ce0246f480cd2baca44a7477fee98662917b7',
        'csv:///data/rowb3f0c7f6bb763af1be91d9e74eabfeb199dc1f1f'-'csv:///schema#column_header'-("9"^^xsd:string),
        'csv:///data/rowb3f0c7f6bb763af1be91d9e74eabfeb199dc1f1f'-'csv:///schema#column_some'-("1"^^xsd:string),
        'csv:///data/rowb3f0c7f6bb763af1be91d9e74eabfeb199dc1f1f'-(rdf:type)-'csv:///schema#Row_c40ce0246f480cd2baca44a7477fee98662917b7'
    ].

test(csv_dump,
     [setup((setup_temp_store(State),
             create_db_without_schema("admin", "testdb")
            )),
      cleanup(teardown_temp_store(State))]
    ) :-

    tmp_file_stream(Filename, Stream, [encoding(utf8)]),
    format(Stream, "some,header~n", []),
    format(Stream, "1,2~n", []),
    format(Stream, "3,4~n", []),
    close(Stream),

    Path = 'admin/testdb',
    Files = [csv=Filename],
    Commit_Info = _{ author : "me", message : "a message"},
    open_descriptor(system_descriptor{}, System_DB),
    super_user_authority(Auth),
    csv_load(System_DB, Auth, Path, Commit_Info, Files, []),

    csv_dump(System_DB, Auth, Path, CSV_Files, []),

    member(csv=CSV_Filename, CSV_Files),
    open(CSV_Filename, read, Read_Stream),
    read_string(Read_Stream, _, String),

    % newline depends on platform
    re_match("some,header(\r\n|\n)1,2(\r\n|\n)3,4(\r\n|\n)",String).


test(csv_load_multiple,
     [setup((setup_temp_store(State),
             create_db_without_schema("admin", "testdb")
            )),
      cleanup(teardown_temp_store(State))]
    ) :-

    Path = 'admin/testdb',

    tmp_file_stream(Filename1, Stream1, [encoding(utf8)]),
    format(Stream1, "some,header~n", []),
    format(Stream1, "1,2~n", []),
    format(Stream1, "3,4~n", []),
    close(Stream1),


    tmp_file_stream(Filename2, Stream2, [encoding(utf8)]),
    format(Stream2, "another,one~n", []),
    format(Stream2, "888.8,Goofball~n", []),
    format(Stream2, "99.9,Fuzzbucket~n", []),
    close(Stream2),

    Files = [csv1=Filename1, csv2=Filename2],

    Commit_Info = _{ author : "me", message : "a message"},
    open_descriptor(system_descriptor{}, System_DB),
    super_user_authority(Auth),

    csv_load(System_DB, Auth, Path, Commit_Info, Files, []),

    resolve_absolute_string_descriptor(Path, Desc),

    findall(X-Y-Z, ask(Desc,t(X, Y, Z)), Triples),
    Triples = [
        'csv:///data/ColumnObject_csv1_header'-'csv:///schema#column_name'-("header"^^xsd:string),
        'csv:///data/ColumnObject_csv1_header'-'csv:///schema#index'-(1^^xsd:integer),
        'csv:///data/ColumnObject_csv1_header'-(rdf:type)-'csv:///schema#Column',
        'csv:///data/ColumnObject_csv1_some'-'csv:///schema#column_name'-("some"^^xsd:string),
        'csv:///data/ColumnObject_csv1_some'-'csv:///schema#index'-(0^^xsd:integer),
        'csv:///data/ColumnObject_csv1_some'-(rdf:type)-'csv:///schema#Column',
        'csv:///data/ColumnObject_csv2_another'-'csv:///schema#column_name'-("another"^^xsd:string),
        'csv:///data/ColumnObject_csv2_another'-'csv:///schema#index'-(0^^xsd:integer),
        'csv:///data/ColumnObject_csv2_another'-(rdf:type)-'csv:///schema#Column',
        'csv:///data/ColumnObject_csv2_one'-'csv:///schema#column_name'-("one"^^xsd:string),
        'csv:///data/ColumnObject_csv2_one'-'csv:///schema#index'-(1^^xsd:integer),
        'csv:///data/ColumnObject_csv2_one'-(rdf:type)-'csv:///schema#Column',
        'csv:///data/csv1'-'csv:///schema#column'-'csv:///data/ColumnObject_csv1_header',
        'csv:///data/csv1'-'csv:///schema#column'-'csv:///data/ColumnObject_csv1_some',
        'csv:///data/csv1'-'csv:///schema#row'-'csv:///data/row7b52009b64fd0a2a49e6d8a939753077792b0554',
        'csv:///data/csv1'-'csv:///schema#row'-'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59',
        'csv:///data/csv1'-(rdf:type)-'csv:///schema#Csv',
        'csv:///data/csv1'-(rdfs:label)-("csv1"^^xsd:string),
        'csv:///data/csv2'-'csv:///schema#column'-'csv:///data/ColumnObject_csv2_another',
        'csv:///data/csv2'-'csv:///schema#column'-'csv:///data/ColumnObject_csv2_one',
        'csv:///data/csv2'-'csv:///schema#row'-'csv:///data/row61a9be6a4ed0500fd8cbad8a734b2b6613cee256',
        'csv:///data/csv2'-'csv:///schema#row'-'csv:///data/rowff4486a1156a60f60967e314f083cb2b26c37bfe',
        'csv:///data/csv2'-(rdf:type)-'csv:///schema#Csv',
        'csv:///data/csv2'-(rdfs:label)-("csv2"^^xsd:string),
        'csv:///data/row61a9be6a4ed0500fd8cbad8a734b2b6613cee256'-'csv:///schema#column_another'-("888.8"^^xsd:string),
        'csv:///data/row61a9be6a4ed0500fd8cbad8a734b2b6613cee256'-'csv:///schema#column_one'-("Goofball"^^xsd:string),
        'csv:///data/row61a9be6a4ed0500fd8cbad8a734b2b6613cee256'-(rdf:type)-'csv:///schema#Row_fed7a6d119f9a3c725a6939b8b5c3f0fa6305031',
        'csv:///data/row7b52009b64fd0a2a49e6d8a939753077792b0554'-'csv:///schema#column_header'-("2"^^xsd:string),
        'csv:///data/row7b52009b64fd0a2a49e6d8a939753077792b0554'-'csv:///schema#column_some'-("1"^^xsd:string),
        'csv:///data/row7b52009b64fd0a2a49e6d8a939753077792b0554'-(rdf:type)-'csv:///schema#Row_c40ce0246f480cd2baca44a7477fee98662917b7',
        'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59'-'csv:///schema#column_header'-("4"^^xsd:string),
        'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59'-'csv:///schema#column_some'-("3"^^xsd:string),
        'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59'-(rdf:type)-'csv:///schema#Row_c40ce0246f480cd2baca44a7477fee98662917b7',
        'csv:///data/rowff4486a1156a60f60967e314f083cb2b26c37bfe'-'csv:///schema#column_another'-("99.9"^^xsd:string),
        'csv:///data/rowff4486a1156a60f60967e314f083cb2b26c37bfe'-'csv:///schema#column_one'-("Fuzzbucket"^^xsd:string),
        'csv:///data/rowff4486a1156a60f60967e314f083cb2b26c37bfe'-(rdf:type)-'csv:///schema#Row_fed7a6d119f9a3c725a6939b8b5c3f0fa6305031'
    ].

test(csv_update_multiple,
     [setup((setup_temp_store(State),
             create_db_without_schema("admin", "testdb")
            )),
      cleanup(teardown_temp_store(State))]
    ) :-

    Path = 'admin/testdb',

    tmp_file_stream(Filename1, Stream1, [encoding(utf8)]),
    format(Stream1, "some,header~n", []),
    format(Stream1, "1,2~n", []),
    format(Stream1, "3,4~n", []),
    close(Stream1),


    tmp_file_stream(Filename2, Stream2, [encoding(utf8)]),
    format(Stream2, "another,one~n", []),
    format(Stream2, "888.8,Goofball~n", []),
    format(Stream2, "99.9,Fuzzbucket~n", []),
    close(Stream2),

    Files = [csv1=Filename1, csv2=Filename2],
    Commit_Info = _{ author : "me", message : "a message"},
    open_descriptor(system_descriptor{}, System_DB),
    super_user_authority(Auth),
    csv_load(System_DB, Auth, Path, Commit_Info, Files, []),

    tmp_file_stream(Filename3, Stream3, [encoding(utf8)]),
    format(Stream3, "some,header~n", []),
    format(Stream3, "1,9~n", []),
    format(Stream3, "3,4~n", []),
    close(Stream3),

    tmp_file_stream(Filename4, Stream4, [encoding(utf8)]),
    format(Stream4, "another,one~n", []),
    format(Stream4, "666,Goofball~n", []),
    format(Stream4, "99.9,Fuzzbucket~n", []),
    close(Stream4),

    Files2 = [csv1=Filename3, csv2=Filename4],
    open_descriptor(system_descriptor{}, System_DB2),
    csv_update(System_DB2, Auth, Path, Commit_Info, Files2, []),

    resolve_absolute_string_descriptor(Path, Desc),
    findall(X-Y-Z, ask(Desc,t(X, Y, Z)), Triples),

    Triples = [
        'csv:///data/ColumnObject_csv1_header'-'csv:///schema#column_name'-("header"^^xsd:string),
        'csv:///data/ColumnObject_csv1_header'-'csv:///schema#index'-(1^^xsd:integer),
        'csv:///data/ColumnObject_csv1_header'-(rdf:type)-'csv:///schema#Column',
        'csv:///data/ColumnObject_csv1_some'-'csv:///schema#column_name'-("some"^^xsd:string),
        'csv:///data/ColumnObject_csv1_some'-'csv:///schema#index'-(0^^xsd:integer),
        'csv:///data/ColumnObject_csv1_some'-(rdf:type)-'csv:///schema#Column',
        'csv:///data/ColumnObject_csv2_another'-'csv:///schema#column_name'-("another"^^xsd:string),
        'csv:///data/ColumnObject_csv2_another'-'csv:///schema#index'-(0^^xsd:integer),
        'csv:///data/ColumnObject_csv2_another'-(rdf:type)-'csv:///schema#Column',
        'csv:///data/ColumnObject_csv2_one'-'csv:///schema#column_name'-("one"^^xsd:string),
        'csv:///data/ColumnObject_csv2_one'-'csv:///schema#index'-(1^^xsd:integer),
        'csv:///data/ColumnObject_csv2_one'-(rdf:type)-'csv:///schema#Column',
        'csv:///data/csv1'-'csv:///schema#column'-'csv:///data/ColumnObject_csv1_header',
        'csv:///data/csv1'-'csv:///schema#column'-'csv:///data/ColumnObject_csv1_some',
        'csv:///data/csv1'-'csv:///schema#row'-'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59',
        'csv:///data/csv1'-'csv:///schema#row'-'csv:///data/rowb3f0c7f6bb763af1be91d9e74eabfeb199dc1f1f',
        'csv:///data/csv1'-(rdf:type)-'csv:///schema#Csv',
        'csv:///data/csv1'-(rdfs:label)-("csv1"^^xsd:string),
        'csv:///data/csv2'-'csv:///schema#column'-'csv:///data/ColumnObject_csv2_another',
        'csv:///data/csv2'-'csv:///schema#column'-'csv:///data/ColumnObject_csv2_one',
        'csv:///data/csv2'-'csv:///schema#row'-'csv:///data/rowff4486a1156a60f60967e314f083cb2b26c37bfe',
        'csv:///data/csv2'-'csv:///schema#row'-'csv:///data/row127d3117b32a00b1042b6c64186080ae36f4a14c',
        'csv:///data/csv2'-(rdf:type)-'csv:///schema#Csv',
        'csv:///data/csv2'-(rdfs:label)-("csv2"^^xsd:string),
        'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59'-'csv:///schema#column_header'-("4"^^xsd:string),
        'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59'-'csv:///schema#column_some'-("3"^^xsd:string),
        'csv:///data/rowf1f836cb4ea6efb2a0b1b99f41ad8b103eff4b59'-(rdf:type)-'csv:///schema#Row_c40ce0246f480cd2baca44a7477fee98662917b7',
        'csv:///data/rowff4486a1156a60f60967e314f083cb2b26c37bfe'-'csv:///schema#column_another'-("99.9"^^xsd:string),
        'csv:///data/rowff4486a1156a60f60967e314f083cb2b26c37bfe'-'csv:///schema#column_one'-("Fuzzbucket"^^xsd:string),
        'csv:///data/rowff4486a1156a60f60967e314f083cb2b26c37bfe'-(rdf:type)-'csv:///schema#Row_fed7a6d119f9a3c725a6939b8b5c3f0fa6305031',
        'csv:///data/row127d3117b32a00b1042b6c64186080ae36f4a14c'-'csv:///schema#column_another'-("666"^^xsd:string),
        'csv:///data/row127d3117b32a00b1042b6c64186080ae36f4a14c'-'csv:///schema#column_one'-("Goofball"^^xsd:string),
        'csv:///data/row127d3117b32a00b1042b6c64186080ae36f4a14c'-(rdf:type)-'csv:///schema#Row_fed7a6d119f9a3c725a6939b8b5c3f0fa6305031',
        'csv:///data/rowb3f0c7f6bb763af1be91d9e74eabfeb199dc1f1f'-'csv:///schema#column_header'-("9"^^xsd:string),
        'csv:///data/rowb3f0c7f6bb763af1be91d9e74eabfeb199dc1f1f'-'csv:///schema#column_some'-("1"^^xsd:string),
        'csv:///data/rowb3f0c7f6bb763af1be91d9e74eabfeb199dc1f1f'-(rdf:type)-'csv:///schema#Row_c40ce0246f480cd2baca44a7477fee98662917b7'
    ].

:- end_tests(csv_api).
