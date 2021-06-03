:- module('document/json', [
              context_triple/2,
              json_elaborate/3,
              json_triple/4,
              %json_schema_triple/2,
              json_schema_triple/3,
              json_schema_elaborate/2,
              get_document/3,
              delete_document/2,
              insert_document/3,
              update_document/3,
              database_context/2,
              create_graph_from_json/5,
              write_json_stream_to_builder/3,
              write_json_stream_to_schema/2,
              write_json_stream_to_instance/2,
              write_json_string_to_schema/2,
              write_json_string_to_instance/2
          ]).

:- use_module(instance).
:- use_module(schema).

:- use_module(library(pcre)).
:- use_module(library(yall)).
:- use_module(library(apply_macros)).
:- use_module(library(terminus_store)).
:- use_module(library(http/json)).

:- use_module(core(util)).
:- use_module(core(query)).
:- use_module(core(triple)).
:- use_module(core(transaction)).

value_json(X,O) :-
    O = json{
            '@type': "@id",
            '@id': X
        },
    string(X),
    !.
value_json(RDF_Nil,json{}) :-
    global_prefix_expand(rdf:nil,RDF_Nil),
    !.
value_json(X^^Y,O) :-
    O = json{
            '@type': Y,
            '@value': X
        },
    !.
value_json(X@Y,O) :-
    O = json{
            '@lang': Y,
            '@value': X
        },
    !.
value_json(X,X) :-
    atom(X).

get_all_path_values(JSON,Path_Values) :-
    findall(Path-Value,
            get_path_value(JSON,Path,Value),
            Path_Values).

% TODO: Arrays
get_value(Elaborated, _) :-
    get_dict('@type', Elaborated, "@id"),
    !,
    throw(error(no_hash_possible_over_ids(Elaborated))).
get_value(Elaborated,Value) :-
    is_dict(Elaborated),
    get_dict('@type',Elaborated,"@container"),
    !,
    get_dict('@value',Elaborated, List),
    member(Elt,List),
    get_value(Elt,Value).
get_value(Elaborated,Value) :-
    is_dict(Elaborated),
    get_dict('@value',Elaborated,_),
    !,
    value_json(Value,Elaborated).

get_path_value(Elaborated,Path,Value) :-
    is_dict(Elaborated),
    get_dict('@type',Elaborated,_),
    !,
    dict_pairs(Elaborated,json,Pairs),
    % Remove ID if it exists
    (   select('@id'-_,Pairs,Pairs1)
    ->  true
    ;   Pairs = Pairs1),
    % remove type?
    % select('@type'-_,Pairs1,Pairs2),

    member(P-V,Pairs1),

    (   P = '@type',
        atom(V)
    ->  Path = [P],
        V = Value
    ;   get_value(V,Value)
    ->  Path = [P]
    ;   get_path_value(V,Sub_Path,Value),
        Path = [P|Sub_Path]
    ).

get_field_values(JSON,Fields,Values) :-
    findall(
        Value,
        (   member(Field,Fields),
            (   get_dict(Field,JSON,Value)
            ->  true
            ;   throw(error(missing_key(Field,JSON),_))
            )
        ),
        Values).

raw(JValue,Value) :- get_dict('@value',JValue,Value).

idgen_lexical(Base,Values,ID) :-
    maplist(raw,Values,Raw),
    maplist(uri_encoded(path),Raw,Encoded),
    merge_separator_split(Suffix, '_', Encoded),
    format(string(ID), '~w~w', [Base,Suffix]).

idgen_hash(Base,Values,ID) :-
    maplist(raw,Values,Raw),
    maplist(uri_encoded(path),Raw,Encoded),
    merge_separator_split(String, '_', Encoded),
    md5_hash(String,Hash,[]),
    format(string(ID), "~w~w", [Base,Hash]).

idgen_path_values_hash(Base,Path,ID) :-
    format(string(A), '~q', [Path]),
    md5_hash(A,Hash,[]),
    format(string(ID), "~w~w", [Base,Hash]).

idgen_random(Base,ID) :-
    random(X),
    format(string(S), '~w', [X]),
    md5_hash(S,Hash,[]),
    format(string(ID),'~w~w',[Base,Hash]).

json_idgen(DB,JSON,ID) :-
    get_dict('@type',JSON,Type),
    key_descriptor(DB,Type,Descriptor),
    (   Descriptor = lexical(Base,Fields)
    ->  get_field_values(JSON, Fields, Values),
        idgen_lexical(Base,Values,ID)
    ;   Descriptor = hash(Base,Fields),
        get_field_values(JSON, Fields, Values),
        idgen_hash(Base,Values,ID)
    ;   Descriptor = value_hash(Base)
    ->  get_all_path_values(JSON,Path_Values),
        idgen_path_values_hash(Base,Path_Values,ID)
    ;   Descriptor = random(Base)
    ->  idgen_random(Base,ID)
    ).

class_descriptor_image(unit,json{}).
class_descriptor_image(class(_),json{ '@type' : "@id" }).
class_descriptor_image(optional(_),json{ '@type' : "@id" }).
class_descriptor_image(tagged_union(_,_),json{ '@type' : "@id" }).
class_descriptor_image(base_class(C),json{ '@type' : C }).
class_descriptor_image(enum(C,_),json{ '@type' : C }).
class_descriptor_image(list(C),json{ '@container' : "@list",
                                     '@type' : C }).
class_descriptor_image(array(C),json{ '@container' : "@array",
                                      '@type' : C }).
class_descriptor_image(set(C),json{ '@container' : "@set",
                                    '@type' : C }).
class_descriptor_image(cardinality(C,_), json{ '@container' : "@set",
                                               '@type' : C }).

database_context(DB,Context) :-
    database_schema(DB,Schema),
    (   xrdf(Schema, ID, rdf:type, sys:'Context')
    ->  id_schema_json(DB,ID,Pre_Context),
        select_dict(json{'@id' : _ }, Pre_Context, Context)
    ;   Context = _{}).

predicate_map(P, Context, Prop, json{ '@id' : P }) :-
    % NOTE: This is probably wrong if it already has a prefix...
    get_dict('@schema', Context, Base),
    atomic_list_concat([Base,'(.*)'],Pat),
    re_matchsub(Pat, P, Match, []),
    !,
    get_dict(1,Match,Short),
    atom_string(Prop,Short).
predicate_map(P, _Context, P, json{}).

type_context(_DB, "@id", json{}) :- !.
type_context(_DB, Base_Type, json{}) :-
    is_base_type(Base_Type),
    !.
type_context(DB,Type,Context) :-
    database_context(DB, Database_Context),
    maybe_expand_type(Type,Database_Context,TypeEx),
    do_or_die(is_simple_class(DB, TypeEx),
              error(type_not_found(Type), _)),
    findall(Prop - C,
          (
              class_predicate_type(DB, TypeEx, P, Desc),
              class_descriptor_image(Desc, Image),
              predicate_map(P,Database_Context,Prop, Map),
              put_dict(Map,Image,C)
          ),
          Edges),
    dict_create(Context,json,Edges).

json_elaborate(DB,JSON,JSON_ID) :-
    database_context(DB,Context),
    json_elaborate(DB,JSON,Context,JSON_ID).

maybe_expand_type(Type,Context,TypeEx) :-
    get_dict('@schema', Context, Schema),
    put_dict(_{'@base' : Schema}, Context, New_Context),
    prefix_expand(Type, New_Context, TypeEx).

json_elaborate(DB,JSON,Context,JSON_ID) :-
    is_dict(JSON),
    !,
    get_dict('@type',JSON,Type),
    maybe_expand_type(Type,Context,TypeEx),
    do_or_die(
        type_context(DB,TypeEx,Type_Context),
        error(unknown_type_encountered(TypeEx),_)),

    put_dict(Type_Context,Context,New_Context),
    json_context_elaborate(DB,JSON,New_Context,Elaborated),
    json_jsonid(DB,Elaborated,JSON_ID).

expansion_key(Key,Expansion,Prop,Cleaned) :-
    (   select_dict(json{'@id' : Prop}, Expansion, Cleaned)
    ->  true
    ;   Key = Prop,
        Expansion = Cleaned
    ).


value_expand_list([], _DB, _Context, _Elt_Type, []).
value_expand_list([Value|Vs], DB, Context, Elt_Type, [Expanded|Exs]) :-
    (   is_enum(DB,Elt_Type)
    ->  enum_value(Elt_Type,Value,Expanded)
    ;   is_dict(Value)
    ->  put_dict(json{'@type':Elt_Type}, Value, Prepared)
    ;   is_base_type(Elt_Type)
    ->  Prepared = json{'@value' : Value,
                        '@type': Elt_Type}
    ;   Prepared = json{'@id' : Value,
                        '@type': "@id"}),
    json_elaborate(DB, Prepared, Expanded),
    value_expand_list(Vs, DB, Context, Elt_Type, Exs).

context_value_expand(_,_,json{},json{},json{}) :-
    !.
context_value_expand(DB,Context,Value,Expansion,V) :-
    get_dict('@container', Expansion, _),
    !,
    % Container type
    get_dict('@type', Expansion, Elt_Type),
    (   is_list(Value)
    ->  Value_List = Value
    ;   string(Value)
    ->  Value_List = [Value]
    ;   get_dict('@value',Value,Value_List)),
    value_expand_list(Value_List, DB, Context, Elt_Type, Expanded_List),
    V = (Expansion.put(json{'@value' : Expanded_List})).
context_value_expand(DB,Context,Value,Expansion,V) :-
    % A possible reference
    get_dict('@type', Expansion, "@id"),
    !,
    is_dict(Value),
    json_elaborate(DB, Value, Context, V).
context_value_expand(_,_Context, Value,_Expansion,V) :-
    % An already expanded typed value
    is_dict(Value),
    get_dict('@value',Value,_),
    !,
    V = Value.
context_value_expand(DB,_Context,Value,Expansion,V) :-
    % An unexpanded typed value
    New_Expansion = (Expansion.put(json{'@value' : Value})),
    json_elaborate(DB,New_Expansion, V).

enum_value(Type,Value,ID) :-
    atomic_list_concat([Type, '_', Value], ID).

json_context_elaborate(DB, JSON, Context, Expanded) :-
    is_dict(JSON),
    get_dict('@type',JSON,Type),
    maybe_expand_type(Type,Context,Type_Ex),
    is_enum(DB,Type_Ex),
    !,
    get_dict('@value',JSON,Value),
    enum_value(Type,Value,Full_ID),
    Expanded = json{ '@type' : "@id",
                     '@id' : Full_ID }.
json_context_elaborate(DB, JSON, Context, Expanded) :-
    is_dict(JSON),
    !,
    dict_pairs(JSON,json,Pairs),
    findall(
        P-V,
        (   member(Prop-Value,Pairs),
            (   get_dict(Prop, Context, Full_Expansion),
                is_dict(Full_Expansion)
            ->  expansion_key(Prop,Full_Expansion,P,Expansion),
                context_value_expand(DB,Context,Value,Expansion,V)
            ;   Prop = '@type'
            ->  P = Prop,
                maybe_expand_type(Value,Context, V)
            ;   has_at(Prop)
            ->  P = Prop,
                V = Value
            ;   throw(error(unrecognized_prop_value(Prop,Value), _))
            )
        ),
        PVs),
    dict_pairs(Expanded,json,PVs).

json_jsonid(DB,JSON,JSON_ID) :-
    % Set up the ID
    (   get_dict('@id',JSON,_)
    ->  JSON_ID = JSON
    ;   get_dict('@container', JSON, _)
    ->  JSON_ID = JSON
    ;   get_dict('@value', JSON, _)
    ->  JSON_ID = JSON
    ;   json_idgen(DB,JSON,ID)
    ->  JSON_ID = (JSON.put(json{'@id' : ID}))
    ;   throw(error(no_id(JSON),_))
    ).


json_prefix_access(JSON,Edge,Type) :-
    global_prefix_expand(Edge,Expanded),
    get_dict(Expanded,JSON,Type).

json_type(JSON,_Context,Type) :-
    json_prefix_access(JSON,rdf:type,Type).

json_schema_elaborate(JSON,Elaborated) :-
    json_schema_elaborate(JSON,[],Elaborated).

is_type_family(Dict) :-
    get_dict('@type',Dict,Type_Constructor),
    maybe_expand_schema_type(Type_Constructor,Expanded),
    type_family_constructor(Expanded).

type_family_parts(JSON,['Cardinality',Class,Cardinality]) :-
    get_dict('@type',JSON,"Cardinality"),
    !,
    get_dict('@class',JSON, Class),
    get_dict('@cardinality',JSON, Cardinality).
type_family_parts(JSON,[Family,Class]) :-
    get_dict('@type',JSON, Family),
    get_dict('@class',JSON, Class).

type_family_id(JSON,Path,ID) :-
    reverse(Path,Rev),
    type_family_parts(JSON,Parts),
    append(Rev,Parts,Full_Path),
    maplist(uri_encoded(path),Full_Path,Encoded),
    merge_separator_split(Merged,'_',Encoded),
    ID = Merged.

key_parts(JSON,[Type|Fields]) :-
    get_dict('@type',JSON,Type),
    get_dict('@fields',JSON,Fields),
    !.
key_parts(JSON,[Type]) :-
    get_dict('@type',JSON,Type).

key_id(JSON,Path,ID) :-
    reverse(Path,Rev),
    key_parts(JSON,Parts),
    append(Rev,Parts,Full_Path),
    maplist(uri_encoded(path),Full_Path,Encoded),
    merge_separator_split(Merged,'_',Encoded),
    ID = Merged.

maybe_expand_schema_type(Type, Expanded) :-
    (   re_match('.*:.*', Type)
    ->  Type = Expanded
    ;   global_prefix_expand(sys:Type,Expanded)
    ).

is_context(JSON) :-
    get_dict('@type', JSON, "@context").

% NOTE: We probably need the prefixes in play here...
is_type_enum(JSON) :-
    get_dict('@type', JSON, "Enum"),
    !.
is_type_enum(JSON) :-
    global_prefix_expand(sys:'Enum', Enum),
    get_dict('@type', JSON, Enum).

context_triple(JSON,Triple) :-
    context_elaborate(JSON,Elaborated),
    expand(Elaborated,JSON{
                          sys:'http://terminusdb.com/schema/sys#',
                          xsd:'http://www.w3.org/2001/XMLSchema#',
                          xdd:'http://terminusdb.com/schema/xdd#'
                      },
           Expanded),
    json_triple_(Expanded,Triple).

context_keyword_value_map('@type',"@context",'@type','sys:Context').
context_keyword_value_map('@base',Value,'sys:base',json{'@type' : "xsd:string", '@value' : Value}).
context_keyword_value_map('@schema',Value,'sys:schema',json{'@type' : "xsd:string", '@value' : Value}).

context_elaborate(JSON,Elaborated) :-
    is_context(JSON),
    !,
    dict_pairs(JSON,json,Pairs),
    partition([P-_]>>(member(P, ['@type', '@base', '@schema'])),
              Pairs, Keyword_Values, Prop_Values),
    findall(
        P-V,
        (   member(Keyword-Value,Keyword_Values),
            context_keyword_value_map(Keyword,Value,P,V)
        ),
        PVs),

    findall(
        Prefix_Pair,
        (   member(Prop-Value, Prop_Values),
            idgen_hash('terminusdb://Prefix_Pair_',[json{'@value' : Prop},
                                                    json{'@value' : Value}], HashURI),
            Prefix_Pair = json{'@type' : 'sys:Prefix',
                               '@id' : HashURI,
                               'sys:prefix' : json{ '@value' : Prop,
                                                    '@type' : "xsd:string"},
                               'sys:url' : json{ '@value' : Value,
                                                 '@type' : "xsd:string"}
                              }
        ),
        Prefix_Pair_List),

    dict_pairs(Elaborated,json,['@id'-"terminusdb://context",
                                'sys:prefix_pair'-json{ '@container' : "@set",
                                                        '@type' : "sys:Prefix",
                                                        '@value' : Prefix_Pair_List }
                                |PVs]).

wrap_id(ID, json{'@type' : "@id",
                 '@id' : ID}) :-
    (   atom(ID)
    ;   string(ID)),
    !.
wrap_id(ID, ID).

expand_match_system(Key,Term,Key_Ex) :-
    global_prefixes(sys,Prefix),
    global_prefix_expand(sys:Term,Key_Ex),
    prefix_expand(Key, _{'@base' : Prefix}, Key_Ex).

json_schema_elaborate_key(V,json{'@type':Value}) :-
    atom(V),
    !,
    global_prefixes(sys,Prefix),
    prefix_expand(V, _{'@base' : Prefix}, Value).
json_schema_elaborate_key(V,Value) :-
    get_dict('@type', V, Lexical),
    expand_match_system(Lexical, 'Lexical', Type),
    !,
    get_dict('@fields', V, Fields),
    maplist([Elt,Elt_ID]>>wrap_id(Elt,Elt_ID), Fields, Fields_Wrapped),
    Value = json{
                '@type' : Type,
                'sys:fields' :
                json{
                    '@container' : "@list",
                    '@type' : "@id",
                    '@value' : Fields_Wrapped
                }
            }.
json_schema_elaborate_key(V,Value) :-
    get_dict('@type', V, Hash),
    expand_match_system(Hash, 'Hash', Type),
    !,
    get_dict('@fields', V, Fields),
    maplist([Elt,Elt_ID]>>wrap_id(Elt,Elt_ID), Fields, Fields_Wrapped),
    Value = json{
                '@type' : Type,
                'sys:fields' :
                json{
                    '@container' : "@list",
                    '@type' : "@id",
                    '@value' : Fields_Wrapped
                }
            }.
json_schema_elaborate_key(V,json{ '@type' : Type}) :-
    get_dict('@type', V, ValueHash),
    expand_match_system(ValueHash, 'ValueHash', Type),
    !.
json_schema_elaborate_key(V,json{ '@type' : Type}) :-
    get_dict('@type', V, Random),
    expand_match_system(Random, 'Random', Type),
    !.

json_schema_predicate_value('@id',V,_,'@id',V) :-
    !.
json_schema_predicate_value('@cardinality',V,_,P,json{'@type' : 'xsd:nonNegativeInteger',
                                                      '@value' : V }) :-
    global_prefix_expand(sys:cardinality, P),
    !.
json_schema_predicate_value('@key',V,Path,P,Value) :-
    !,
    global_prefix_expand(sys:key, P),
    json_schema_elaborate_key(V,Elab),
    key_id(V,Path,ID),
    put_dict(_{'@id' : ID}, Elab, Value).
json_schema_predicate_value('@base',V,_,P,Value) :-
    !,
    global_prefix_expand(sys:base, P),
    (   is_dict(V)
    ->  Value = V
    ;   global_prefix_expand(xsd:string, XSD),
        Value = json{ '@type' : XSD,
                      '@value' : V }
    ).
json_schema_predicate_value('@type',V,_,'@type',Value) :-
    !,
    maybe_expand_schema_type(V,Value).
json_schema_predicate_value('@class',V,_,Class,json{'@type' : "@id",
                                                    '@id' : V}) :-
    !,
    global_prefix_expand(sys:class, Class).
json_schema_predicate_value(P,V,Path,P,Value) :-
    is_dict(V),
    !,
    json_schema_elaborate(V, [P|Path], Value).
json_schema_predicate_value(P,V,_,P,json{'@type' : "@id",
                                         '@id' : V }).

json_schema_elaborate(JSON,_,Elaborated) :-
    is_type_enum(JSON),
    !,
    get_dict('@id', JSON, ID),
    get_dict('@type', JSON, Type),
    maybe_expand_schema_type(Type,Expanded),
    get_dict('@value', JSON, List),
    maplist({ID}/[Elt,json{'@type' : "@id",
                           '@id' : V}]>>(
                format(string(V),'~w_~w',[ID,Elt])
            ),List,New_List),
    Elaborated = json{ '@id' : ID,
                       '@type' : Expanded,
                       'sys:value' : json{ '@container' : "@list",
                                           '@type' : "@id",
                                           '@value' : New_List } }.
json_schema_elaborate(JSON,Old_Path,Elaborated) :-
    is_dict(JSON),
    dict_pairs(JSON,json,Pre_Pairs),
    !,
    (   is_type_family(JSON)
    ->  type_family_id(JSON,Old_Path,ID),
        Pairs = ['@id'-ID|Pre_Pairs]
    ;   Pairs = Pre_Pairs,
        get_dict('@id',JSON,ID)
    ),
    Path = [ID|Old_Path],
    findall(
        Prop-Value,
        (   member(P-V,Pairs),
            json_schema_predicate_value(P,V,Path,Prop,Value)
        ),
        PVs),
    dict_pairs(Elaborated,json,PVs).

expand_schema(JSON,Prefixes,Expanded) :-
    get_dict('@schema', Prefixes, Schema),
    put_dict(_{'@base' : Schema}, Prefixes, Schema_Prefixes),
    expand(JSON,Schema_Prefixes,Expanded).

json_schema_triple(JSON,Context,Triple) :-
    json_schema_elaborate(JSON,JSON_Schema),
    expand_schema(JSON_Schema,Context,Expanded),
    json_triple_(Expanded,Triple).

/*
json_schema_triple(JSON,Triple) :-
    json_schema_elaborate(JSON,JSON_Schema),
    json_triple_(JSON_Schema,Triple).
*/

% Triple generator
json_triple(DB,JSON,Context,Triple) :-
    json_elaborate(DB,JSON,Elaborated),
    expand(Elaborated,Context,Expanded),
    json_triple_(Expanded,Triple).

json_triples(DB,JSON,Context,Triples) :-
    findall(
        Triple,
        json_triple(DB, JSON, Context, Triple),
        Triples).

json_triple_(JSON,_Triple) :-
    is_dict(JSON),
    get_dict('@value', JSON, _),
    \+ get_dict('@container', JSON, _),
    !,
    fail.
json_triple_(JSON,Triple) :-
    is_dict(JSON),
    !,
    % NOTE: Need to do something with containers separately
    dict_keys(JSON,Keys),

    (   get_dict('@id', JSON, ID)
    ->  true
    ;   throw(error(no_id(JSON), _))
    ),

    member(Key, Keys),
    get_dict(Key,JSON,Value),
    (   Key = '@id'
    ->  fail
    ;   Key = '@type', % this is a leaf
        Value = "@id"
    ->  fail
    ;   Key = '@type'
    ->  global_prefix_expand(rdf:type, RDF_Type),
        Triple = t(ID,RDF_Type,Value)
    ;   Key = '@inherits'
    ->  global_prefix_expand(sys:inherits, SYS_Inherits),
        (    get_dict('@value',Value,Class)
        ->  (   is_dict(Class)
            ->  get_dict('@id', Class, Inherited)
            ;   Inherited = Class),
            Triple = t(ID,SYS_Inherits,Inherited)
        ;   get_dict('@id', Value, Inherited)
        ->  Triple = t(ID,SYS_Inherits,Inherited))
    ;   (   get_dict('@id', Value, Value_ID)
        ->  (   json_triple_(Value, Triple)
            ;   Triple = t(ID,Key,Value_ID)
            )
        ;   get_dict('@container', Value, "@list")
        ->  get_dict('@value', Value, List),
            list_id_key_triple(List,ID,Key,Triple)
        ;   get_dict('@container', Value, "@array")
        ->  get_dict('@value', Value, Array),
            array_id_key_triple(Array,ID,Key,Triple)
        ;   get_dict('@container', Value, "@set")
        ->  get_dict('@value', Value, Set),
            set_id_key_triple(Set,ID,Key,Triple)
        ;   value_json(Lit,Value),
            Triple = t(ID,Key,Lit)
        )
    ).

array_id_key_triple(List,ID,Key,Triple) :-
    array_index_id_key_triple(List,0,ID,Key,Triple).

array_index_id_key_triple([H|T],Index,ID,Key,Triple) :-
    idgen_random('Array_',New_ID),
    reference(H,HRef),
    global_prefix_expand(sys:value, SYS_Value),
    global_prefix_expand(sys:index, SYS_Index),
    global_prefix_expand(xsd:nonNegativeInteger, XSD_NonNegativeInteger),
    (   Triple = t(ID, Key, New_ID)
    ;   Triple = t(New_ID, SYS_Value, HRef)
    ;   Triple = t(New_ID, SYS_Index, Index^^XSD_NonNegativeInteger)
    ;   Next_Index is Index + 1,
        array_index_id_key_triple(T,Next_Index,ID,Key,Triple)
    ;   json_triple_(H,Triple)
    ).

set_id_key_triple([H|T],ID,Key,Triple) :-
    (   reference(H,HRef),
        Triple = t(ID,Key,HRef)
    ;   set_id_key_triple(T,ID,Key,Triple)
    ;   json_triple_(H,Triple)
    ).

reference(Dict,ID) :-
    get_dict('@id',Dict, ID),
    !.
reference(Elt,V) :-
    value_json(V,Elt).

list_id_key_triple([],ID,Key,t(ID,Key,RDF_Nil)) :-
    global_prefix_expand(rdf:nil, RDF_Nil).
list_id_key_triple([H|T],ID,Key,Triple) :-
    idgen_random('Cons_',New_ID),
    (   Triple = t(ID,Key,New_ID)
    ;   reference(H,HRef),
        global_prefix_expand(rdf:first, RDF_First),
        Triple = t(New_ID,RDF_First,HRef)
    ;   global_prefix_expand(rdf:rest, RDF_Rest),
        list_id_key_triple(T,New_ID,RDF_Rest,Triple)
    ;   json_triple_(H,Triple)
    ).

rdf_list_list(_Graph, RDF_Nil,[]) :-
    global_prefix_expand(rdf:nil,RDF_Nil),
    !.
rdf_list_list(Graph, Cons,[H|L]) :-
    xrdf(Graph, Cons, rdf:first, H),
    xrdf(Graph, Cons, rdf:rest, Tail),
    rdf_list_list(Graph,Tail,L).

array_list(DB,Id,P,List) :-
    database_instance(DB,Instance),
    findall(
        I-V,
        (   xrdf(Instance,Id,P,ArrayElement),
            xrdf(Instance,ArrayElement,sys:value,V),
            xrdf(Instance,ArrayElement,sys:index,I^^_)
        ),
        Index_List),
    keysort(Index_List, Index_List_Sorted),
    index_list_array(Index_List_Sorted,List).

index_list_array(Index_List, List) :-
    index_list_last_array(Index_List,0,List).

index_list_last_array([], _, []) :-
    !.
index_list_last_array([I-Value|T], I, [Value|List]) :-
    !,
    J is I + 1,
    index_list_last_array(T,J,List).
index_list_last_array(Index_List, I, [null|List]) :-
    (   I > 174763
    ->  throw(error(index_on_array_too_large(I),_))
    ;   true
    ),

    J is I + 1,
    index_list_last_array(Index_List,J,List).

set_list(DB,Id,P,Set) :-
    % NOTE: This will not give an empty list.
    database_instance(DB,Instance),
    setof(V,xrdf(Instance,Id,P,V),Set),
    !.

list_type_id_predicate_value([],_,_,_,_,_,[]).
list_type_id_predicate_value([O|T],C,Id,P,DB,Prefixes,[V|L]) :-
    type_id_predicate_iri_value(C,Id,P,O,DB,Prefixes,V),
    list_type_id_predicate_value(T,C,Id,P,DB,Prefixes,L).

type_id_predicate_iri_value(enum(C,_),_,_,V,_,_,O) :-
    merge_separator_split(V, '_', [C,O]).
type_id_predicate_iri_value(list(C),Id,P,O,DB,Prefixes,L) :-
    % Probably need to treat enums...
    database_instance(DB,Instance),
    rdf_list_list(Instance,O,V),
    type_descriptor(DB,C,Desc),
    list_type_id_predicate_value(V,Desc,Id,P,DB,Prefixes,L).
type_id_predicate_iri_value(array(C),Id,P,_,DB,Prefixes,L) :-
    array_list(DB,Id,P,V),
    type_descriptor(DB,C,Desc),
    list_type_id_predicate_value(V,Desc,Id,P,DB,Prefixes,L).
type_id_predicate_iri_value(set(C),Id,P,_,DB,Prefixes,L) :-
    set_list(DB,Id,P,V),
    type_descriptor(DB,C,Desc),
    list_type_id_predicate_value(V,Desc,Id,P,DB,Prefixes,L).
type_id_predicate_iri_value(cardinality(C,_),Id,P,_,DB,Prefixes,L) :-
    set_list(DB,Id,P,V),
    type_descriptor(DB,C,Desc),
    list_type_id_predicate_value(V,Desc,Id,P,DB,Prefixes,L).
type_id_predicate_iri_value(class(_),_,_,Id,_,Prefixes,Id_Comp) :-
    compress_dict_uri(Id, Prefixes, Id_Comp).
type_id_predicate_iri_value(tagged_union(_,_),_,_,V,_,_,V).
type_id_predicate_iri_value(optional(C),Id,P,O,DB,Prefixes,V) :-
    type_descriptor(DB,C,Desc),
    type_id_predicate_iri_value(Desc,Id,P,O,DB,Prefixes,V).
type_id_predicate_iri_value(base_class(_),_,_,O,_,_,S) :-
    typecast(O,'http://www.w3.org/2001/XMLSchema#string', [], S^^_).

compress_schema_uri(IRI,Prefixes,IRI_Comp) :-
    get_dict('@schema',Prefixes,Schema),
    put_dict(_{'@base' : Schema}, Prefixes, Schema_Prefixes),
    compress_dict_uri(IRI,Schema_Prefixes,IRI_Comp).

get_document(Query_Context, Id, Document) :-
    is_query_context(Query_Context),
    !,
    query_default_collection(Query_Context, TO),
    get_document(TO, Id, Document).
get_document(Desc, Id, Document) :-
    is_descriptor(Desc),
    !,
    open_descriptor(Desc,Transaction),
    get_document(Transaction, Id, Document).
get_document(DB, Id, Document) :-
    database_context(DB,Prefixes),
    database_instance(DB,Instance),

    prefix_expand(Id,Prefixes,Id_Ex),
    xrdf(Instance, Id_Ex, rdf:type, Class),
    findall(
        Prop-Value,
        (   distinct([P],xrdf(Instance,Id_Ex,P,O)),
            \+ is_built_in(P),

            once(class_predicate_type(DB,Class,P,Type)),
            type_id_predicate_iri_value(Type,Id_Ex,P,O,DB,Prefixes,Value),

            compress_schema_uri(P, Prefixes, Prop)
        ),
        Data),
    !,
    compress_dict_uri(Id_Ex, Prefixes, Id_comp),
    compress_schema_uri(Class, Prefixes, Class_comp),
    dict_create(Document,json,['@id'-Id_comp,
                               '@type'-Class_comp
                               |Data]).

key_descriptor_json(lexical(_, Fields), json{ '@type' : "Lexical",
                                              '@fields' : Fields }).
key_descriptor_json(hash(_, Fields), json{ '@type' : "Hash",
                                           '@fields' : Fields }).
key_descriptor_json(value_hash(_), json{ '@type' : "ValueHash" }).
key_descriptor_json(random(_), json{ '@type' : "Random" }).

type_descriptor_json(unit, "Unit").
type_descriptor_json(class(C), C).
type_descriptor_json(optional(C), json{ '@type' : "Optional",
                                        '@class' : C }).
type_descriptor_json(set(C), json{ '@type' : "Set",
                                   '@class' : C }).
type_descriptor_json(array(C), json{ '@type' : "Array",
                                   '@class' : C }).
type_descriptor_json(list(C), json{ '@type' : "List",
                                    '@class' : C }).
type_descriptor_json(tagged_union(C,_), C).
type_descriptor_json(enum(C,_), C).

schema_subject_predicate_object_key_value(_,_Id,P,O^^_,'@base',O) :-
    global_prefix_expand(sys:base,P),
    !.
schema_subject_predicate_object_key_value(_,_Id,P,O^^_,'@schema',O) :-
    global_prefix_expand(sys:schema,P),
    !.
schema_subject_predicate_object_key_value(_,_Id,P,O,'@class',O) :-
    global_prefix_expand(sys:class,P),
    !.
schema_subject_predicate_object_key_value(DB,_Id,P,O,'@value',L) :-
    global_prefix_expand(sys:value,P),
    !,
    database_schema(DB,Schema),
    rdf_list_list(Schema, O, L).
schema_subject_predicate_object_key_value(DB,_Id,P,O,'@key',V) :-
    global_prefix_expand(sys:key,P),
    !,
    key_descriptor(DB, O, Key),
    key_descriptor_json(Key,V).
schema_subject_predicate_object_key_value(DB,_Id,P,O,P,JSON) :-
    type_descriptor(DB, O, Descriptor),
    type_descriptor_json(Descriptor,JSON).

id_schema_json(DB, Id, JSON) :-
    database_schema(DB,Schema),
    xrdf(Schema, Id, rdf:type, Class),

    findall(
        K-V,
        (   distinct([P],xrdf(Schema,Id,P,O)),
            schema_subject_predicate_object_key_value(DB,Id,P,O,K,V)
        ),
        Data),
    !,
    dict_create(JSON,json,['@id'-Id,
                           '@type'-Class
                           |Data]).

%%
% create_graph_from_json(+Store,+Graph_ID,+JSON_Stream,+Type:graph_type,-Layer) is det.
%
% Type := instance | schema(Database)
%
create_graph_from_json(Store, Graph_ID, JSON_Stream, Type, Layer) :-
    safe_create_named_graph(Store,Graph_ID,Graph_Obj),
    open_write(Store, Builder),

    write_json_stream_to_builder(JSON_Stream, Builder, Type),
    % commit this builder to a temporary layer to perform a diff.
    nb_commit(Builder,Layer),
    nb_set_head(Graph_Obj, Layer).

write_json_stream_to_builder(JSON_Stream, Builder, schema) :-
    !,
    json_read_dict(JSON_Stream, Context, [default_tag(json),end_of_file(eof)]),

    (   Context = eof
    ;   is_dict(Context),
        \+ get_dict('@type', Context, "@context")
    ->  throw(error(no_context_found_in_schema,_))
    ;   true
    ),

    forall(
        context_triple(Context,t(S,P,O)),
        (
            object_storage(O,OS),
            nb_add_triple(Builder, S, P, OS)
        )
    ),

    default_prefixes(Prefixes),
    put_dict(Context,Prefixes,Expanded_Context),

    forall(
        json_read_dict_stream(JSON_Stream, Dict),
        (
            forall(
                json_schema_triple(Dict,Expanded_Context,t(S,P,O)),
                (
                    object_storage(O,OS),
                    nb_add_triple(Builder, S, P, OS)
                )
            )
        )
    ).
write_json_stream_to_builder(JSON_Stream, Builder, instance(DB)) :-
    database_context(DB,Context),
    default_prefixes(Prefixes),

    put_dict(Context,Prefixes,Expanded_Context),

    forall(
        json_read_dict_stream(JSON_Stream, Dict),
        (
            forall(
                json_triple(DB,Dict,Expanded_Context,t(S,P,O)),
                (
                    object_storage(O,OS),
                    nb_add_triple(Builder, S, P, OS)
                )
            )
        )
    ).

write_json_stream_to_schema(Transaction, Stream) :-
    transaction_object{} :< Transaction,
    !,
    [RWO] = (Transaction.schema_objects),
    read_write_obj_builder(RWO, Builder),

    write_json_stream_to_builder(Stream, Builder, schema).

write_json_stream_to_schema(Context, Stream) :-
    query_context{transaction_objects: [Transaction]} :< Context,
    write_json_stream_to_schema(Transaction, Stream).

write_json_stream_to_instance(Transaction, Stream) :-
    transaction_object{} :< Transaction,
    !,
    [RWO] = (Transaction.instance_objects),
    read_write_obj_builder(RWO, Builder),

    write_json_stream_to_builder(Stream, Builder, schema(Transaction)).

write_json_stream_to_instance(Context, Stream) :-
    query_context{transaction_objects: [Transaction]} :< Context,
    write_json_stream_to_instance(Transaction, Stream).

write_json_string_to_schema(Context, String) :-
    open_string(String, Stream),
    write_json_stream_to_schema(Context, Stream).

write_json_string_to_instance(Context, String) :-
    open_string(String, Stream),
    write_json_stream_to_instance(Context, Stream).

json_to_database_type(D^^T, OC) :-
    (   string(D)
    ;   atom(D)),
    !,
    typecast(D^^'http://www.w3.org/2001/XMLSchema#string', T, [], OC).
json_to_database_type(D^^T, OC) :-
    number(D),
    !,
    typecast(D^^'http://www.w3.org/2001/XMLSchema#decimal', T, [], OC).
json_to_database_type(O, O).

%% Document insert / delete / update

run_delete_document(Desc, Commit, ID) :-
    create_context(Desc,Commit,Context),
    with_transaction(
        Context,
        delete_document(Context, ID),
        _).

delete_document(Query_Context, Id) :-
    is_query_context(Query_Context),
    !,
    query_default_collection(Query_Context, TO),
    delete_document(TO, Id).
delete_document(DB, Id) :-
    database_context(DB,Prefixes),
    database_instance(DB,Instance),
    prefix_expand(Id,Prefixes,Id_Ex),
    (   xrdf(Instance, Id_Ex, rdf:type, _)
    ->  true
    ;   throw(error(document_does_not_exist(Id),_))
    ),
    forall(
        xquad(Instance, G, Id_Ex, P, V),
        delete(G, Id_Ex, P, V, _)
    ).

insert_document(Query_Context, Document, ID) :-
    is_query_context(Query_Context),
    !,
    query_default_collection(Query_Context, TO),
    insert_document(TO, Document, ID).
insert_document(Transaction, Document, ID) :-
    database_context(Transaction, Prefixes),
    % Pre process document
    json_elaborate(Transaction, Document, Elaborated),
    !,
    expand(Elaborated, Prefixes, Expanded),
    !,
    insert_document_expanded(Transaction, Expanded, ID).

insert_document_expanded(Transaction, Expanded, ID) :-
    get_dict('@id', Expanded, ID),
    database_instance(Transaction, [Instance]),
    % insert
    forall(
        json_triple_(Expanded, t(S,P,O)),
        (   json_to_database_type(O,OC),
            insert(Instance, S, P, OC, _))
    ).

run_insert_document(Desc, Commit, Document, ID) :-
    create_context(Desc,Commit,Context),
    with_transaction(
        Context,
        insert_document(Context, Document, ID),
        _).

update_document(Transaction, Document) :-
    update_document(Transaction, Document, _).
update_document(Query_Context, Document) :-
    is_query_context(Query_Context),
    !,
    query_default_collection(Query_Context, TO),
    update_document(TO, Document).

update_document(Transaction, Document, Id) :-
    database_context(Transaction, Prefixes),
    json_elaborate(Transaction, Document, Elaborated),
    expand(Elaborated, Prefixes, Expanded),
    get_dict('@id', Expanded, Id),
    delete_document(Transaction, Id),
    insert_document_expanded(Transaction, Expanded, Id).
update_document(Query_Context, Document, Id) :-
    is_query_context(Query_Context),
    !,
    query_default_collection(Query_Context, TO),
    update_document(TO, Document, Id).

run_update_document(Desc, Commit, Document, Id) :-
    create_context(Desc,Commit,Context),
    with_transaction(
        Context,
        update_document(Context, Document, Id),
        _).

:- begin_tests(json_stream).
:- use_module(core(util)).
:- use_module(library(terminus_store)).
:- use_module(core(query), [ask/2]).

test(write_json_stream_to_builder, [
         setup(
             (   open_memory_store(Store),
                 open_write(Store,Builder)
             )
         )
     ]) :-

    open_string(
    '{ "@type" : "@context",
       "@base" : "http://terminusdb.com/system/schema#",
        "type" : "http://terminusdb.com/type#" }

     { "@id" : "User",
       "@type" : "Class",
       "key_hash" : "type:string",
       "capability" : { "@type" : "Set",
                        "@class" : "Capability" } }',Stream),

    write_json_stream_to_builder(Stream, Builder,schema),
    nb_commit(Builder,Layer),

    findall(
        t(X,Y,Z),
        triple(Layer,X,Y,Z),
        Triples),

    Triples = [
        t("http://terminusdb.com/system/schema#User",
          "http://terminusdb.com/system/schema#capability",
          node("http://terminusdb.com/system/schema#User_capability_Set_Capability")),
        t("http://terminusdb.com/system/schema#User",
          "http://terminusdb.com/system/schema#key_hash",
          node("http://terminusdb.com/type#string")),
        t("http://terminusdb.com/system/schema#User",
          "http://www.w3.org/1999/02/22-rdf-syntax-ns#type",
          node("http://terminusdb.com/schema/sys#Class")),
        t("http://terminusdb.com/system/schema#User_capability_Set_Capability",
          "http://terminusdb.com/schema/sys#class",
          node("http://terminusdb.com/system/schema#Capability")),
        t("http://terminusdb.com/system/schema#User_capability_Set_Capability",
          "http://www.w3.org/1999/02/22-rdf-syntax-ns#type",
          node("http://terminusdb.com/schema/sys#Set")),
        t("terminusdb://Prefix_Pair_5450b0648f2f15c2864f8853747d484b",
          "http://terminusdb.com/schema/sys#prefix",
          value("\"type\"^^'http://www.w3.org/2001/XMLSchema#string'")),
        t("terminusdb://Prefix_Pair_5450b0648f2f15c2864f8853747d484b",
          "http://terminusdb.com/schema/sys#url",
          value("\"http://terminusdb.com/type#\"^^'http://www.w3.org/2001/XMLSchema#string'")),
        t("terminusdb://Prefix_Pair_5450b0648f2f15c2864f8853747d484b",
          "http://www.w3.org/1999/02/22-rdf-syntax-ns#type",
          node("http://terminusdb.com/schema/sys#Prefix")),
        t("terminusdb://context",
          "http://terminusdb.com/schema/sys#base",
          value("\"http://terminusdb.com/system/schema#\"^^'http://www.w3.org/2001/XMLSchema#string'")),
        t("terminusdb://context",
          "http://terminusdb.com/schema/sys#prefix_pair",
          node("terminusdb://Prefix_Pair_5450b0648f2f15c2864f8853747d484b")),
        t("terminusdb://context",
          "http://www.w3.org/1999/02/22-rdf-syntax-ns#type",
          node("http://terminusdb.com/schema/sys#Context"))
    ].

:- end_tests(json_stream).

:- begin_tests(json).

:- use_module(core(util/test_utils)).

schema1('
{ "@type" : "@context",
  "@base" : "http://i/",
  "@schema" : "http://s/" }

{ "@id" : "Person",
  "@type" : "Class",
  "name" : "xsd:string",
  "birthdate" : "xsd:date",
  "friends" : { "@type" : "Set",
                "@class" : "Person" } }

{ "@id" : "Employee",
  "@type" : "Class",
  "@inherits" : "Person",
  "staff_number" : "xsd:string",
  "boss" : { "@type" : "Optional",
                 "@class" : "Employee" },
  "tasks" : { "@type" : "List",
                    "@class" : "Task" } }

{ "@id" : "Task",
  "@type" : "Class",
  "name" : "xsd:string" }

{ "@id" : "Criminal",
  "@type" : "Class",
  "@inherits" : "Person",
  "aliases" : { "@type" : "List",
                "@class" : "xsd:string" } }').

write_schema1(Desc) :-
    create_context(Desc,commit{
                            author : "me",
                            message : "none"},
                   Context),

    schema1(Schema1),

    % Schema
    with_transaction(
        Context,
        write_json_string_to_schema(Context, Schema1),
        _Meta).

test(create_database_context,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema1(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-
    open_descriptor(Desc, DB),
    type_context(DB,'Employee',Context),

    Context = json{ birthdate:json{ '@id':'http://s/birthdate',
		                            '@type':'http://www.w3.org/2001/XMLSchema#date'
		                          },
                    boss:json{'@id':'http://s/boss','@type':"@id"},
                    friends:json{'@container':"@set",
                                 '@id':'http://s/friends',
                                 '@type':'http://s/Person'},
                    name:json{ '@id':'http://s/name',
		                       '@type':'http://www.w3.org/2001/XMLSchema#string'
	                         },
                    staff_number:json{ '@id':'http://s/staff_number',
			                           '@type':'http://www.w3.org/2001/XMLSchema#string'
		                             },
                    tasks:json{'@container':"@list",'@id':'http://s/tasks','@type':'http://s/Task'}
                  }.

test(elaborate,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema1(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    Document = json{
                   '@id' : gavin,
                   '@type' : 'Criminal',
                   name : "gavin",
                   birthdate : "1977-05-24",
                   aliases : ["gavino", "gosha"]
               },

    open_descriptor(Desc, DB),

    json_elaborate(DB, Document, Elaborated),

    Elaborated = json{ '@id':gavin,
                       '@type':'http://s/Criminal',
                       'http://s/aliases':
                       _{ '@container':"@list",
			              '@type':'http://www.w3.org/2001/XMLSchema#string',
			              '@value':[ json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
					                       '@value':"gavino"
					                     },
				                     json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
					                       '@value':"gosha"
					                     }
				                   ]
			            },
                       'http://s/birthdate':json{ '@type':'http://www.w3.org/2001/XMLSchema#date',
				                                  '@value':"1977-05-24"
			                                    },
                       'http://s/name':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
			                                 '@value':"gavin"
			                               }
                     }.

test(id_expand,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema1(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    Document = json{
                   '@id' : gavin,
                   '@type' : 'Employee',
                   name : "gavin",
                   staff_number : "13",
                   birthdate : "1977-05-24",
                   boss : json{
                              '@id' : jane,
                              '@type' : 'Employee',
                              name : "jane",
                              staff_number : "12",
                              birthdate : "1979-12-28"
                          }
               },

    open_descriptor(Desc, DB),
    json_elaborate(DB, Document, Elaborated),

    Elaborated =
    json{
        '@id':gavin,
        '@type':'http://s/Employee',
        'http://s/birthdate':json{ '@type':'http://www.w3.org/2001/XMLSchema#date',
				                   '@value':"1977-05-24"
			                     },
        'http://s/boss':json{ '@id':jane,
			                  '@type':'http://s/Employee',
			                  'http://s/birthdate':json{ '@type':'http://www.w3.org/2001/XMLSchema#date',
						                                 '@value':"1979-12-28"
						                               },
			                  'http://s/name':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
						                            '@value':"jane"
						                          },
			                  'http://s/staff_number':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
							                                '@value':"12"
							                              }
			                },
        'http://s/name':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
			                  '@value':"gavin"
			                },
        'http://s/staff_number':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
				                      '@value':"13"
				                    }
    }.

test(triple_convert,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema1(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    Document = json{
                   '@id' : gavin,
                   '@type' : 'Employee',
                   name : "gavin",
                   staff_number : "13",
                   birthdate : "1977-05-24",
                   boss : json{
                              '@id' : jane,
                              '@type' : 'Employee',
                              name : "jane",
                              staff_number : "12",
                              birthdate : "1979-12-28"
                          }
               },

    open_descriptor(Desc, DB),
    database_context(DB, Context),
    json_triples(DB, Document, Context, Triples),

    sort(Triples, Sorted),

    Sorted = [
        t('http://i/gavin',
          'http://s/birthdate',
          "1977-05-24"^^'http://www.w3.org/2001/XMLSchema#date'),
        t('http://i/gavin','http://s/boss','http://i/jane'),
        t('http://i/gavin',
          'http://s/name',
          "gavin"^^'http://www.w3.org/2001/XMLSchema#string'),
        t('http://i/gavin',
          'http://s/staff_number',
          "13"^^'http://www.w3.org/2001/XMLSchema#string'),
        t('http://i/gavin',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          'http://s/Employee'),
        t('http://i/jane',
          'http://s/birthdate',
          "1979-12-28"^^'http://www.w3.org/2001/XMLSchema#date'),
        t('http://i/jane',
          'http://s/name',
          "jane"^^'http://www.w3.org/2001/XMLSchema#string'),
        t('http://i/jane',
          'http://s/staff_number',
          "12"^^'http://www.w3.org/2001/XMLSchema#string'),
        t('http://i/jane',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          'http://s/Employee')
    ].

test(extract_json,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema1(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    Document = json{
                   '@id' : gavin,
                   '@type' : 'Employee',
                   name : "gavin",
                   staff_number : "13",
                   birthdate : "1977-05-24",
                   boss : json{
                              '@id' : jane,
                              '@type' : 'Employee',
                              name : "jane",
                              staff_number : "12",
                              birthdate : "1979-12-28"
                          }
               },

    run_insert_document(Desc, commit_info{ author: "Luke Skywalker",
                                           message: "foo" },
                        Document, Id),

    open_descriptor(Desc, DB),
    !, % NOTE: why does rolling back over this go mental?

    get_document(DB,Id,JSON1),
    !,
    JSON1 = json{'@id':gavin,
                 '@type':'Employee',
                 birthdate:"1977-05-24",
                 boss:jane,
                 name:"gavin",
                 staff_number:"13"},

    get_document(DB,jane,JSON2),
    !,
    JSON2 = json{ '@id':jane,
                  '@type':'Employee',
                  birthdate:"1979-12-28",
                  name:"jane",
                  staff_number:"12"
                }.

test(get_value,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema1(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@id':jane,
                '@type':'Employee',
                birthdate:"1979-12-28",
                name:"jane",
                staff_number:"12"},

    open_descriptor(Desc, DB),
    json_elaborate(DB,JSON,Elaborated),

    get_all_path_values(Elaborated,Values),

    Values = [['@type']-'http://s/Employee',
              ['http://s/birthdate']-("1979-12-28"^^'http://www.w3.org/2001/XMLSchema#date'),
              ['http://s/name']-("jane"^^'http://www.w3.org/2001/XMLSchema#string'),
              ['http://s/staff_number']-("12"^^'http://www.w3.org/2001/XMLSchema#string')].

schema2('
{ "@type" : "@context",
  "@base" : "http://i/",
  "@schema" : "http://s/" }

{ "@id" : "Person",
  "@type" : "Class",
  "@base" : "Person_",
  "@key" : { "@type" : "Lexical",
             "@fields" : [ "name", "birthdate" ] },
  "name" : "xsd:string",
  "birthdate" : "xsd:date",
  "friends" : { "@type" : "Set",
                "@class" : "Person" } }

{ "@id" : "Employee",
  "@type" : "Class",
  "@inherits" : "Person",
  "@base" : "Employee_",
  "@key" : { "@type" : "Hash",
             "@fields" : [ "name", "birthdate" ] },
  "staff_number" : "xsd:string",
  "boss" : { "@type" : "Optional",
             "@class" : "Employee" },
  "tasks" : { "@type" : "List",
              "@class" : "Task" } }

{ "@id" : "Task",
  "@type" : "Class",
  "@key" : { "@type" : "ValueHash" },
  "name" : "xsd:string" }

{ "@id" : "Criminal",
  "@type" : "Class",
  "@inherits" : "Person",
  "aliases" : { "@type" : "List",
                "@class" : "xsd:string" } }

{ "@id" : "Event",
  "@type" : "Class",
  "@key" : { "@type" : "Random" },
  "action" : "xsd:string",
  "timestamp" : "xsd:dateTime" }

{ "@id" : "Book",
  "@type" : "Class",
  "@key" : { "@type" : "Lexical",
             "@fields" : ["name"] },
  "name" : "xsd:string" }

{ "@id" : "BookClub",
  "@type" : "Class",
  "@base" : "BookClub_",
  "@key" : { "@type" : "Lexical",
             "@fields" : ["name"] },
  "name" : "xsd:string",
  "people" : { "@type" : "Set",
               "@class" : "Person" },
  "book_list" : { "@type" : "Array",
                  "@class" : "Book" } }

{ "@id" : "Colour",
  "@type" : "Enum",
  "@value" : [ "red", "blue", "green" ] }

{ "@id" : "Dog",
  "@type" : "Class",
  "@base" : "Dog_",
  "@key" : { "@type" : "Lexical",
             "@fields" : [ "name" ] },
  "name" : "xsd:string",
  "hair_colour" : "Colour" }

{ "@id" : "BinaryTree",
  "@type" : "TaggedUnion",
  "@base" : "binary_tree_",
  "@key" : { "@type" : "ValueHash" },
  "leaf" : "sys:Unit",
  "node" : "Node" }

{ "@id" : "Node",
  "@type" : "Class",
  "@key" : { "@type" : "ValueHash" },
  "value" : "xsd:integer",
  "left" : "BinaryTree",
  "right" : "BinaryTree" }').

write_schema2(Desc) :-
    create_context(Desc,commit{
                            author : "me",
                            message : "none"},
                   Context),

    schema2(Schema1),

    % Schema
    with_transaction(
        Context,
        write_json_string_to_schema(Context, Schema1),
        _Meta).

test(schema_key_elaboration1, []) :-
    Doc = json{'@id':"Capability",
               '@key':json{'@type':"ValueHash"},
               '@type':"Class",
               role:json{'@class':"Role",
                         '@type':"Set"},
               scope:"Resource"},
    json_schema_elaborate(Doc, Elaborate),

    Elaborate = json{ '@id':"Capability",
                      '@type':'http://terminusdb.com/schema/sys#Class',
                      'http://terminusdb.com/schema/sys#key':
                      json{
                          '@id':'Capability_ValueHash',
                          '@type':'http://terminusdb.com/schema/sys#ValueHash'
					  },
                      role:json{ '@id':'Capability_role_Set_Role',
		                         '@type':'http://terminusdb.com/schema/sys#Set',
		                         'http://terminusdb.com/schema/sys#class':
                                 json{ '@id':"Role",
								       '@type':"@id"
							         }
	                           },
                      scope:json{'@id':"Resource",'@type':"@id"}
                    }.

test(schema_lexical_key_elaboration, []) :-
    Doc = json{ '@id' : "Person",
                '@type' : "Class",
                '@base' : "Person_",
                '@key' : json{ '@type' : "Lexical",
                               '@fields' : [ "name", "birthdate" ] },
                'name' : "xsd:string",
                'birthdate' : "xsd:date",
                'friends' : json{ '@type' : "Set",
                                  '@class' : "Person" } },

    json_schema_elaborate(Doc, Elaborate),

    Elaborate =
    json{ '@id':"Person",
          '@type':'http://terminusdb.com/schema/sys#Class',
          birthdate:json{'@id':"xsd:date",'@type':"@id"},
          friends:json{ '@id':'Person_friends_Set_Person',
		                '@type':'http://terminusdb.com/schema/sys#Set',
		                'http://terminusdb.com/schema/sys#class':json{ '@id':"Person",
								                                       '@type':"@id"
								                                     }
		              },
          'http://terminusdb.com/schema/sys#base':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
						                                '@value':"Person_"
						                              },
          'http://terminusdb.com/schema/sys#key':json{ '@id':'Person_Lexical_name_birthdate',
						                               '@type':'http://terminusdb.com/schema/sys#Lexical',
						                               'sys:fields':json{ '@container':"@list",
								                                          '@type':"@id",
								                                          '@value': [ json{ '@id':"name",
										                                                    '@type':"@id"
										                                                  },
										                                              json{ '@id':"birthdate",
										                                                    '@type':"@id"
										                                                  }
									                                                ]
								                                        }
						                             },
          name:json{'@id':"xsd:string",'@type':"@id"}
        }.

test(idgen_lexical,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@type':'Person',
                birthdate:"1979-12-28",
                name:"jane"
               },

    open_descriptor(Desc, DB),
    json_elaborate(DB, JSON, Elaborated),

    Elaborated =
    json{'@id':"Person_jane_1979-12-28",
         '@type':'http://s/Person',
         'http://s/birthdate':json{'@type':'http://www.w3.org/2001/XMLSchema#date',
                                   '@value':"1979-12-28"},
         'http://s/name':json{'@type':'http://www.w3.org/2001/XMLSchema#string',
                              '@value':"jane"}
        }.

test(idgen_hash,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@type':'Employee',
                birthdate:"1979-12-28",
                name:"jane",
                staff_number:"13"
               },

    open_descriptor(Desc, DB),
    json_elaborate(DB, JSON, Elaborated),

    Elaborated =
    json{
        '@id':"Employee_b367edeea1a0e899b55a88edf9b27513",
        '@type':'http://s/Employee',
        'http://s/birthdate':json{ '@type':'http://www.w3.org/2001/XMLSchema#date',
				                   '@value':"1979-12-28"
			                     },
        'http://s/name':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
			                  '@value':"jane"
			                },
        'http://s/staff_number':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
				                      '@value':"13"
				                    }
    }.

test(idgen_value_hash,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@type':'Task',
                name:"Groceries"},

    open_descriptor(Desc, DB),
    json_elaborate(DB,JSON, Elaborated),

    Elaborated =
    json{ '@id':"Task_960ac85fd49f49e99e7e0e82491c90fd",
          '@type':'http://s/Task',
          'http://s/name':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
			                    '@value':"Groceries"
			                  }
        }.

test(idgen_random,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@type': 'Event',
                action: "click click",
                timestamp: "2021-05-20T20:33:00.000Z"
               },

    open_descriptor(Desc, DB),
    json_elaborate(DB, JSON, Elaborated),

    Elaborated =
    json{ '@id':Id,
          '@type':'http://s/Event',
          'http://s/action':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
			                      '@value':"click click"
			                    },
          'http://s/timestamp':json{ '@type':'http://www.w3.org/2001/XMLSchema#dateTime',
				                     '@value':"2021-05-20T20:33:00.000Z"
			                       }
        },

    atom_concat('Event_',_,Id).

test(type_family_id, []) :-

    type_family_id(json{'@type':"Cardinality",
                        '@cardinality':3,
                        '@class':'Person'},
                   [friend_of, 'Person'], 'Person_friend_of_Cardinality_Person_3').

test(schema_elaborate, []) :-

    Schema = json{ '@type' : 'Class',
                   '@id' : 'Person',
                   'name' : 'xsd:string',
                   'age' : json{ '@type' : 'Optional',
                                 '@class' : 'xsd:decimal' },
                   'friend_of' : json{ '@type' : 'Cardinality',
                                       '@class' : 'Person',
                                       '@cardinality' : 3 }
                 },

    json_schema_elaborate(Schema, Elaborated),

    Elaborated =
    json{ '@id':'Person',
          '@type':'http://terminusdb.com/schema/sys#Class',
          age:json{ '@id':'Person_age_Optional_xsd%3Adecimal',
		            '@type':'http://terminusdb.com/schema/sys#Optional',
		            'http://terminusdb.com/schema/sys#class':json{ '@id':'xsd:decimal',
							                                       '@type':"@id"
							                                     }
	              },
          friend_of:json{ '@id':'Person_friend_of_Cardinality_Person',
		                  '@type':'http://terminusdb.com/schema/sys#Cardinality',
		                  'http://terminusdb.com/schema/sys#cardinality':
                          json{ '@type':'xsd:nonNegativeInteger',
								'@value':3
							  },
		                  'http://terminusdb.com/schema/sys#class':json{ '@id':'Person',
								                                         '@type':"@id"
								                                       }
		                },
          name:json{'@id':'xsd:string','@type':"@id"}
        },

    default_prefixes(Prefixes),
    put_dict(_{'@schema' : "https://s#"}, Prefixes, Context),

    findall(Triple,
            json_schema_triple(Schema, Context, Triple),
            Triples),

    sort(Triples,Sorted),
    Sorted = [
        t('https://s#Person',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          'http://terminusdb.com/schema/sys#Class'),
        t('https://s#Person',
          'https://s#age',
          'https://s#Person_age_Optional_xsd%3Adecimal'),
        t('https://s#Person',
          'https://s#friend_of',
          'https://s#Person_friend_of_Cardinality_Person'),
        t('https://s#Person',
          'https://s#name',
          'http://www.w3.org/2001/XMLSchema#string'),
        t('https://s#Person_age_Optional_xsd%3Adecimal',
          'http://terminusdb.com/schema/sys#class',
          'http://www.w3.org/2001/XMLSchema#decimal'),
        t('https://s#Person_age_Optional_xsd%3Adecimal',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          'http://terminusdb.com/schema/sys#Optional'),
        t('https://s#Person_friend_of_Cardinality_Person',
          'http://terminusdb.com/schema/sys#cardinality',
          3^^'http://www.w3.org/2001/XMLSchema#nonNegativeInteger'),
        t('https://s#Person_friend_of_Cardinality_Person',
          'http://terminusdb.com/schema/sys#class',
          'https://s#Person'),
        t('https://s#Person_friend_of_Cardinality_Person',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          'http://terminusdb.com/schema/sys#Cardinality')
    ].

test(list_id_key_triple, []) :-
    findall(Triple,
            list_id_key_triple([json{'@id':"task_a4963868aa3ad8365a4b164a7f206ffc",
                                     '@type':task,
                                     name:json{'@type':xsd:string,
                                               '@value':"Get Groceries"}},
                                json{'@id':"task_f9e4104c952e71025a1d68218d88bab1",
                                     '@type':task,
                                     name:json{'@type':xsd:string,
                                               '@value':"Take out rubbish"}}],
                               elt,
                               p, Triple),
            Triples),
    Triples = [
        t(elt,p,Cons1),
        t(Cons1,'http://www.w3.org/1999/02/22-rdf-syntax-ns#first',"task_a4963868aa3ad8365a4b164a7f206ffc"),
        t(Cons1,'http://www.w3.org/1999/02/22-rdf-syntax-ns#rest',Cons2),
        t(Cons2,'http://www.w3.org/1999/02/22-rdf-syntax-ns#first',"task_f9e4104c952e71025a1d68218d88bab1"),
        t(Cons2,'http://www.w3.org/1999/02/22-rdf-syntax-ns#rest',_Nil),
        t("task_f9e4104c952e71025a1d68218d88bab1",'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',task),
        t("task_f9e4104c952e71025a1d68218d88bab1",name,"Take out rubbish"^^xsd:string),
        t("task_a4963868aa3ad8365a4b164a7f206ffc",'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',task),
        t("task_a4963868aa3ad8365a4b164a7f206ffc",name,"Get Groceries"^^xsd:string)
    ].

test(array_id_key_triple, []) :-
    findall(Triple,
            array_id_key_triple([json{'@id':"task_a4963868aa3ad8365a4b164a7f206ffc",
                                      '@type':task,
                                      name:json{'@type':xsd:string,
                                                '@value':"Get Groceries"}},
                                 json{'@id':"task_f9e4104c952e71025a1d68218d88bab1",
                                      '@type':task,
                                      name:json{'@type':xsd:string,
                                                '@value':"Take out rubbish"}}],
                                elt,
                                p, Triple),
            Triples),

    Triples = [
        t(elt,p,Array0),
        t(Array0,
          'http://terminusdb.com/schema/sys#value',
          "task_a4963868aa3ad8365a4b164a7f206ffc"),
        t(Array0,
          'http://terminusdb.com/schema/sys#index',
          0^^'http://www.w3.org/2001/XMLSchema#nonNegativeInteger'),
        t(elt,p,Array1),
        t(Array1,
          'http://terminusdb.com/schema/sys#value',
          "task_f9e4104c952e71025a1d68218d88bab1"),
        t(Array1,
          'http://terminusdb.com/schema/sys#index',
          1^^'http://www.w3.org/2001/XMLSchema#nonNegativeInteger'),
        t("task_f9e4104c952e71025a1d68218d88bab1",
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          task),
        t("task_f9e4104c952e71025a1d68218d88bab1",
          name,
          "Take out rubbish"^^xsd:string),
        t("task_a4963868aa3ad8365a4b164a7f206ffc",
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          task),
        t("task_a4963868aa3ad8365a4b164a7f206ffc",
          name,
          "Get Groceries"^^xsd:string)
    ].

test(set_id_key_triple, []) :-
    findall(Triple,
            set_id_key_triple([json{'@id':"task_a4963868aa3ad8365a4b164a7f206ffc",
                                      '@type':task,
                                      name:json{'@type':xsd:string,
                                                '@value':"Get Groceries"}},
                                 json{'@id':"task_f9e4104c952e71025a1d68218d88bab1",
                                      '@type':task,
                                      name:json{'@type':xsd:string,
                                                '@value':"Take out rubbish"}}],
                                elt,
                                p, Triple),
            Triples),

    Triples = [
        t(elt,p,"task_a4963868aa3ad8365a4b164a7f206ffc"),
        t(elt,p,"task_f9e4104c952e71025a1d68218d88bab1"),
        t("task_f9e4104c952e71025a1d68218d88bab1",
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          task),
        t("task_f9e4104c952e71025a1d68218d88bab1",
          name,
          "Take out rubbish"^^xsd:string),
        t("task_a4963868aa3ad8365a4b164a7f206ffc",
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          task),
        t("task_a4963868aa3ad8365a4b164a7f206ffc",
          name,
          "Get Groceries"^^xsd:string)
    ].

test(list_elaborate,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@type':'Employee',
                name: "Gavin",
                birthdate: "1977-05-24",
                staff_number: "12",
                tasks : [
                    json{ name : "Get Groceries" },
                    json{ name : "Take out rubbish" }
                ]
               },

    open_descriptor(Desc, DB),
    json_elaborate(DB, JSON, Elaborated),

    Elaborated =
    json{ '@id':"Employee_6f1bb32f84f15c68ac7b69df05967953",
          '@type':'http://s/Employee',
          'http://s/birthdate':json{ '@type':'http://www.w3.org/2001/XMLSchema#date',
				                     '@value':"1977-05-24"
			                       },
          'http://s/name':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
			                    '@value':"Gavin"
			                  },
          'http://s/staff_number':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
				                        '@value':"12"
				                      },
          'http://s/tasks':_{ '@container':"@list",
			                  '@type':'http://s/Task',
			                  '@value':[ json{ '@id':"Task_aaae9b46cb8be52f604b2141434c1d65",
					                           '@type':'http://s/Task',
					                           'http://s/name':
                                               json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
								                     '@value':"Get Groceries"
							                       }
					                         },
				                         json{ '@id':"Task_52a5c6e7da12020f4ac58b51b37610c0",
					                           '@type':'http://s/Task',
					                           'http://s/name':
                                               json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
								                     '@value':"Take out rubbish"
							                       }
					                         }
				                       ]
			}
        },

    database_context(DB, Context),
    json_triples(DB, JSON, Context, Triples),

    Triples = [
        t('http://i/Employee_6f1bb32f84f15c68ac7b69df05967953',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          'http://s/Employee'),
        t('http://i/Employee_6f1bb32f84f15c68ac7b69df05967953',
          'http://s/birthdate',
          "1977-05-24"^^'http://www.w3.org/2001/XMLSchema#date'),
        t('http://i/Employee_6f1bb32f84f15c68ac7b69df05967953',
          'http://s/name',
          "Gavin"^^'http://www.w3.org/2001/XMLSchema#string'),
        t('http://i/Employee_6f1bb32f84f15c68ac7b69df05967953',
          'http://s/staff_number',
          "12"^^'http://www.w3.org/2001/XMLSchema#string'),
        t('http://i/Employee_6f1bb32f84f15c68ac7b69df05967953',
          'http://s/tasks',
          Cons0),
        t(Cons0,
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#first',
          'http://i/Task_aaae9b46cb8be52f604b2141434c1d65'),
        t(Cons0,
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#rest',
          Cons1),
        t(Cons1,
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#first',
          'http://i/Task_52a5c6e7da12020f4ac58b51b37610c0'),
        t(Cons1,
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#rest',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#nil'),
        t('http://i/Task_52a5c6e7da12020f4ac58b51b37610c0',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          'http://s/Task'),
        t('http://i/Task_52a5c6e7da12020f4ac58b51b37610c0',
          'http://s/name',
          "Take out rubbish"^^'http://www.w3.org/2001/XMLSchema#string'),
        t('http://i/Task_aaae9b46cb8be52f604b2141434c1d65',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          'http://s/Task'),
        t('http://i/Task_aaae9b46cb8be52f604b2141434c1d65',
          'http://s/name',
          "Get Groceries"^^'http://www.w3.org/2001/XMLSchema#string')
    ],

    run_insert_document(Desc, commit_object{ author : "me", message : "boo"}, JSON, Id),

    open_descriptor(Desc, New_DB),
    get_document(New_DB, Id, Fresh_JSON),

    Fresh_JSON = json{ '@id':'Employee_6f1bb32f84f15c68ac7b69df05967953',
                       '@type':'Employee',
                       birthdate:"1977-05-24",
                       name:"Gavin",
                       staff_number:"12",
                       tasks:[ 'Task_aaae9b46cb8be52f604b2141434c1d65',
	                           'Task_52a5c6e7da12020f4ac58b51b37610c0'
	                         ]
                     }.

test(array_elaborate,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@type':'BookClub',
                name: "Marxist book club",
                book_list : [
                    json{ name : "Das Kapital" },
                    json{ name : "Der Ursprung des Christentums" }
                ]
               },

    open_descriptor(Desc, DB),
    json_elaborate(DB,JSON,Elaborated),

    Elaborated = json{ '@id':"BookClub_Marxist%20book%20club",
                       '@type':'http://s/BookClub',
                       'http://s/book_list':
                       _{ '@container':"@array",
			              '@type':'http://s/Book',
			              '@value':[ json{ '@id':"Book_Das%20Kapital",
					                       '@type':'http://s/Book',
					                       'http://s/name':
                                           json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
								                 '@value':"Das Kapital"
								               }
					                     },
					                 json{ '@id':"Book_Der%20Ursprung%20des%20Christentums",
					                       '@type':'http://s/Book',
					                       'http://s/name':
                                           json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
								                 '@value':"Der Ursprung des Christentums"
								               }
					                     }
				                   ]
			            },
                       'http://s/name':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
			                                 '@value':"Marxist book club"
			                               }
                     },

    database_context(DB, Context),
    json_triples(DB, JSON, Context, Triples),

    Triples = [
        t('http://i/BookClub_Marxist%20book%20club',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          'http://s/BookClub'),
        t('http://i/BookClub_Marxist%20book%20club',
          'http://s/book_list',
          Array0),
        t(Array0,
          'http://terminusdb.com/schema/sys#value',
          'http://i/Book_Das%20Kapital'),
        t(Array0,
          'http://terminusdb.com/schema/sys#index',
          0^^'http://www.w3.org/2001/XMLSchema#nonNegativeInteger'),
        t('http://i/BookClub_Marxist%20book%20club',
          'http://s/book_list',
          Array1),
        t(Array1,
          'http://terminusdb.com/schema/sys#value',
          'http://i/Book_Der%20Ursprung%20des%20Christentums'),
        t(Array1,
          'http://terminusdb.com/schema/sys#index',
          1^^'http://www.w3.org/2001/XMLSchema#nonNegativeInteger'),
        t('http://i/Book_Der%20Ursprung%20des%20Christentums',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          'http://s/Book'),
        t('http://i/Book_Der%20Ursprung%20des%20Christentums',
          'http://s/name',
          "Der Ursprung des Christentums"^^'http://www.w3.org/2001/XMLSchema#string'),
        t('http://i/Book_Das%20Kapital',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          'http://s/Book'),
        t('http://i/Book_Das%20Kapital',
          'http://s/name',
          "Das Kapital"^^'http://www.w3.org/2001/XMLSchema#string'),
        t('http://i/BookClub_Marxist%20book%20club',
          'http://s/name',
          "Marxist book club"^^'http://www.w3.org/2001/XMLSchema#string')
    ],

    run_insert_document(Desc, commit_object{ author : "me", message : "boo"}, JSON, Id),

    open_descriptor(Desc, New_DB),
    get_document(New_DB, Id, Recovered),
    Recovered = json{ '@id':'BookClub_Marxist%20book%20club',
                      '@type':'BookClub',
                      book_list:[ 'Book_Das%20Kapital',
		                          'Book_Der%20Ursprung%20des%20Christentums'
		                        ],
                      name:"Marxist book club"
                    }.
test(set_elaborate,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@type':'BookClub',
                name: "Marxist book club",
                people: [
                    json{'@type' : 'Person',
                         name : "jim",
                         birthdate: "1982-05-03"
                        },
                    json{'@type':'Person',
                         birthdate:"1979-12-28",
                         name:"jane"
                        }],
                book_list : []
               },

    open_descriptor(Desc, DB),
    json_elaborate(DB, JSON, Elaborated),

    Elaborated =
    json{ '@id':"BookClub_Marxist%20book%20club",
          '@type':'http://s/BookClub',
          'http://s/book_list':_{ '@container':"@array",
			                      '@type':'http://s/Book',
			                      '@value':[]
			                    },
          'http://s/name':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
			                    '@value':"Marxist book club"
			                  },
          'http://s/people':
          _{ '@container':"@set",
			 '@type':'http://s/Person',
			 '@value':[ json{ '@id':"Person_jim_1982-05-03",
					          '@type':'http://s/Person',
					          'http://s/birthdate':
                              json{ '@type':'http://www.w3.org/2001/XMLSchema#date',
								    '@value':"1982-05-03"
								  },
					          'http://s/name':
                              json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
								    '@value':"jim"
								  }
					        },
				        json{ '@id':"Person_jane_1979-12-28",
					          '@type':'http://s/Person',
					          'http://s/birthdate':
                              json{ '@type':'http://www.w3.org/2001/XMLSchema#date',
								    '@value':"1979-12-28"
								  },
					          'http://s/name':
                              json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
								    '@value':"jane"
								  }
					        }
				      ]
		   }
        },

    database_context(DB, Context),
    json_triples(DB, JSON, Context, Triples),

    Triples = [
        t('http://i/BookClub_Marxist%20book%20club',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          'http://s/BookClub'),
        t('http://i/BookClub_Marxist%20book%20club',
          'http://s/name',
          "Marxist book club"^^'http://www.w3.org/2001/XMLSchema#string'),
        t('http://i/BookClub_Marxist%20book%20club',
          'http://s/people',
          'http://i/Person_jim_1982-05-03'),
        t('http://i/BookClub_Marxist%20book%20club',
          'http://s/people',
          'http://i/Person_jane_1979-12-28'),
        t('http://i/Person_jane_1979-12-28',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          'http://s/Person'),
        t('http://i/Person_jane_1979-12-28',
          'http://s/birthdate',
          "1979-12-28"^^'http://www.w3.org/2001/XMLSchema#date'),
        t('http://i/Person_jane_1979-12-28',
          'http://s/name',
          "jane"^^'http://www.w3.org/2001/XMLSchema#string'),
        t('http://i/Person_jim_1982-05-03',
          'http://www.w3.org/1999/02/22-rdf-syntax-ns#type',
          'http://s/Person'),
        t('http://i/Person_jim_1982-05-03',
          'http://s/birthdate',
          "1982-05-03"^^'http://www.w3.org/2001/XMLSchema#date'),
        t('http://i/Person_jim_1982-05-03',
          'http://s/name',
          "jim"^^'http://www.w3.org/2001/XMLSchema#string')
    ],

    run_insert_document(Desc, commit_object{ author : "me", message : "boo"}, JSON, Id),

    open_descriptor(Desc, New_DB),
    get_document(New_DB, Id, Book_Club),

    Book_Club = json{ '@id':'BookClub_Marxist%20book%20club',
                      '@type':'BookClub',
                      name:"Marxist book club",
                      people:['Person_jane_1979-12-28','Person_jim_1982-05-03']
                    }.

test(empty_list,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@type':'Employee',
                name: "Gavin",
                birthdate: "1977-05-24",
                staff_number: "12",
                tasks : []
               },

    run_insert_document(Desc, commit_object{ author : "me", message : "boo"}, JSON, Id),

    open_descriptor(Desc, DB),
    get_document(DB, Id, Employee_JSON),

    Employee_JSON = json{'@id':_,
                         '@type':'Employee',
                         birthdate:"1977-05-24",
                         name:"Gavin",
                         staff_number:"12",
                         tasks:[]}.

test(enum_elaborate,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    open_descriptor(Desc, DB),

    type_context(DB,'Dog',TypeContext),
    TypeContext = json{ hair_colour:json{'@id':'http://s/hair_colour',
                                         '@type':'http://s/Colour'},
                        name:json{ '@id':'http://s/name',
		                           '@type':'http://www.w3.org/2001/XMLSchema#string'
	                             }
                      },

    JSON = json{'@type':'Dog',
                name: "Ralph",
                hair_colour: "blue"
               },

    json_elaborate(DB, JSON, Elaborated),

    Elaborated = json{ '@id':"Dog_Ralph",
                       '@type':'http://s/Dog',
                       'http://s/hair_colour':json{'@id':'http://s/Colour_blue',
                                                   '@type':"@id"},
                       'http://s/name':json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
			                                 '@value':"Ralph"
			                               }
                     },

    run_insert_document(Desc, commit_info{ author: "Luke Skywalker",
                                           message: "foo" },
                        JSON, Id),

    open_descriptor(Desc, New_DB),
    get_document(New_DB,Id, Dog_JSON),

    Dog_JSON = json{'@id':'Dog_Ralph',
                    '@type':'Dog',
                    hair_colour:blue,
                    name:"Ralph"}.

test(elaborate_tagged_union,[]) :-

    Binary_Tree = json{ '@type' : 'TaggedUnion',
                        '@id' : 'BinaryTree',
                        '@base' : "BinaryTree_",
                        '@key' : json{ '@type' : 'ValueHash' },
                        leaf : 'sys:Unit',
                        node : 'Node'
                      },

    Node = json{ '@type' : 'Class',
                 '@id' : 'Node',
                 '@base' : "Node_",
                 '@key' : json{ '@type' : 'ValueHash' },
                 value : 'xsd:integer',
                 left : "BinaryTree",
                 right : "BinaryTree"
               },

    json_schema_elaborate(Binary_Tree, BT_Elaborated),
    BT_Elaborated =json{ '@id':'BinaryTree',
                         '@type':'http://terminusdb.com/schema/sys#TaggedUnion',
                         'http://terminusdb.com/schema/sys#base':
                         json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
						       '@value':"BinaryTree_"
						     },
                         'http://terminusdb.com/schema/sys#key':
                         json{ '@id':'BinaryTree_ValueHash',
						       '@type':'http://terminusdb.com/schema/sys#ValueHash'
						     },
                         leaf:json{'@id':'sys:Unit','@type':"@id"},
                         node:json{'@id':'Node','@type':"@id"}
                       },

    json_schema_elaborate(Node, Node_Elaborated),

    Node_Elaborated = json{'@id':'Node',
                           '@type':'http://terminusdb.com/schema/sys#Class',
                           'http://terminusdb.com/schema/sys#base':
                           json{'@type':'http://www.w3.org/2001/XMLSchema#string',
                                '@value':"Node_"},
                           'http://terminusdb.com/schema/sys#key':
                           json{'@id':'Node_ValueHash',
                                '@type':'http://terminusdb.com/schema/sys#ValueHash'},
                           left:json{'@id':"BinaryTree", '@type':"@id"},
                           right:json{'@id':"BinaryTree", '@type':"@id"},
                           value:json{'@id':'xsd:integer', '@type':"@id"}}.

test(binary_tree_context,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    open_descriptor(Desc, DB),
    type_context(DB,'BinaryTree', Binary_Context),
    Binary_Context = json{ leaf:json{'@id':'http://s/leaf'},
                           node:json{'@id':'http://s/node','@type':"@id"}
                         },
    type_context(DB,'Node', Node_Context),
    Node_Context = json{ left:json{'@id':'http://s/left','@type':"@id"},
                         right:json{'@id':'http://s/right','@type':"@id"},
                         value:json{ '@id':'http://s/value',
		                             '@type':'http://www.w3.org/2001/XMLSchema#integer'
		                           }
                       }.

test(binary_tree_elaborate,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@type':'BinaryTree',
                node: json{'@type':'Node',
                           value: 1,
                           left: json{'@type':'BinaryTree',
                                      node: json{'@type':'Node',
                                                 value: 0,
                                                 left: json{'@type':'BinaryTree',
                                                            leaf : json{}},
                                                 right: json{'@type':'BinaryTree',
                                                             leaf : json{}}}},
                           right: json{'@type':'BinaryTree',
                                      node: json{'@type':'Node',
                                                 value: 2,
                                                 left: json{'@type':'BinaryTree',
                                                            leaf : json{}},
                                                 right: json{'@type':'BinaryTree',
                                                             leaf : json{}}}}}},

    open_descriptor(Desc, DB),
    json_elaborate(DB,JSON,Elaborated),

    Elaborated =
    json{ '@id':"binary_tree_ce4e85e93a3d4818eb1eb6b4d252a3a4",
          '@type':'http://s/BinaryTree',
          'http://s/node':
          json{ '@id':"Node_6ac73e53f5c3956d3b563da380ae0970",
			    '@type':'http://s/Node',
			    'http://s/left':
                json{ '@id':"binary_tree_fd9dd5865a72d5065c9c33ff255bc047",
					  '@type':'http://s/BinaryTree',
					  'http://s/node':
                      json{ '@id':"Node_038aa635227c70af63ce5835b09c2cd0",
							'@type':'http://s/Node',
							'http://s/left':
                            json{ '@id':"binary_tree_ab15c31cac4d1330c35121ad80d15970",
								  '@type':'http://s/BinaryTree',
								  'http://s/leaf':json{}
								},
							'http://s/right':
                            json{ '@id':"binary_tree_ab15c31cac4d1330c35121ad80d15970",
								  '@type':'http://s/BinaryTree',
								  'http://s/leaf':json{}
								},
							'http://s/value':
                            json{ '@type':'http://www.w3.org/2001/XMLSchema#integer',
								  '@value':0
								}
						  }
					},
			    'http://s/right':
                json{ '@id':"binary_tree_d5ea6dfdd40dcf2177bcbbd24c63ef44",
					  '@type':'http://s/BinaryTree',
					  'http://s/node':
                      json{ '@id':"Node_f3b5c54ec90d0178186c20aa44b1044f",
							'@type':'http://s/Node',
							'http://s/left':
                            json{ '@id':"binary_tree_ab15c31cac4d1330c35121ad80d15970",
								  '@type':'http://s/BinaryTree',
								  'http://s/leaf':json{}
								},
							'http://s/right':
                            json{ '@id':"binary_tree_ab15c31cac4d1330c35121ad80d15970",
								  '@type':'http://s/BinaryTree',
								  'http://s/leaf':json{}
								},
							'http://s/value':
                            json{ '@type':'http://www.w3.org/2001/XMLSchema#integer',
								  '@value':2
								}
						  }
					},
			    'http://s/value':
                json{ '@type':'http://www.w3.org/2001/XMLSchema#integer',
					  '@value':1
					}
			  }
        },

    run_insert_document(Desc, commit_object{ author : "me", message : "boo"}, JSON, Id),

    open_descriptor(Desc, New_DB),
    get_document(New_DB, Id, Fresh_JSON),

    Fresh_JSON = json{ '@id':binary_tree_ce4e85e93a3d4818eb1eb6b4d252a3a4,
                       '@type':'BinaryTree',
                       node:'Node_6ac73e53f5c3956d3b563da380ae0970'
                     }.

test(insert_get_delete,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@type':'Dog',
                name: "Ralph",
                hair_colour: "blue"
               },

    run_insert_document(Desc, commit_object{ author : "me", message : "boo"}, JSON, Id),

    get_document(Desc, Id, _),

    run_delete_document(Desc, commit_object{ author : "me", message : "boo"}, Id),

    \+ get_document(Desc, Id, _).


test(document_update,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@type':'Dog',
                name: "Ralph",
                hair_colour: "blue"
               },

    run_insert_document(Desc, commit_object{ author : "me", message : "boo"}, JSON, Id),

    New_JSON = json{'@type':'Dog',
                    '@id' : Id,
                    name: "Ralph",
                    hair_colour: "green"
                   },

    run_update_document(Desc, commit_object{ author : "me", message : "boo"}, New_JSON, Id),

    get_document(Desc, Id, Updated_JSON),

    Updated_JSON = json{'@id':'Dog_Ralph',
                        '@type':'Dog',
                        hair_colour:green,
                        name:"Ralph"}.


test(auto_id_update,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@type':'Dog',
                name: "Ralph",
                hair_colour: "blue"
               },

    run_insert_document(Desc, commit_object{ author : "me", message : "boo"}, JSON, _Id),

    New_JSON = json{'@type':'Dog',
                    name: "Ralph",
                    hair_colour: "green"
                   },

    run_update_document(Desc, commit_object{ author : "me", message : "boo"}, New_JSON, Same_Id),

    get_document(Desc, Same_Id, Updated_JSON),

    Updated_JSON = json{'@id':'Dog_Ralph',
                        '@type':'Dog',
                        hair_colour:green,
                        name:"Ralph"}.

test(partial_document_elaborate,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@id' : 'Dog_Henry',
                '@type':'Dog',
                hair_colour: "blue"
               },

    open_descriptor(Desc, DB),
    json_elaborate(DB,JSON,JSON_ID),

    JSON_ID = json{ '@id':'Dog_Henry',
                    '@type':'http://s/Dog',
                    'http://s/hair_colour':json{'@id':'http://s/Colour_blue',
                                                '@type':"@id"}
                  }.

test(partial_document_elaborate_list,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@id' : 'BookClub_Murder%20Mysteries',
                '@type': 'BookClub',
                name : "Murder Mysteries",
                book_list: [ json{ name : "And Then There Were None" },
                             json{ name : "In Cold Blood" }
                           ]
               },

    open_descriptor(Desc, DB),
    json_elaborate(DB,JSON,JSON_ID),

    JSON_ID = json{ '@id':'BookClub_Murder%20Mysteries',
                    '@type':'http://s/BookClub',
                    'http://s/book_list':
                    _{ '@container':"@array",
			           '@type':'http://s/Book',
			           '@value':
                       [ json{ '@id':"Book_And%20Then%20There%20Were%20None",
					           '@type':'http://s/Book',
					           'http://s/name':
                               json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
								     '@value':"And Then There Were None"
								   }
					         },
					     json{ '@id':"Book_In%20Cold%20Blood",
					           '@type':'http://s/Book',
					           'http://s/name':
                               json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
								     '@value':"In Cold Blood"
								   }
					         }
				       ]
			         },
                    'http://s/name':
                    json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
			              '@value':"Murder Mysteries"
			            }
                  }.

test(partial_document_elaborate_list_without_required,
     [
         setup(
             (   setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema2(Desc)
             )),
         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    JSON = json{'@id' : 'BookClub_Murder%20Mysteries',
                '@type': 'BookClub',
                book_list: [ json{ name : "And Then There Were None" },
                             json{ name : "In Cold Blood" }
                           ]
               },

    open_descriptor(Desc, DB),
    json_elaborate(DB,JSON,JSON_ID),

    JSON_ID = json{ '@id':'BookClub_Murder%20Mysteries',
                    '@type':'http://s/BookClub',
                    'http://s/book_list':
                    _{ '@container':"@array",
			           '@type':'http://s/Book',
			           '@value':
                       [ json{ '@id':"Book_And%20Then%20There%20Were%20None",
					           '@type':'http://s/Book',
					           'http://s/name':
                               json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
								     '@value':"And Then There Were None"
								   }
					         },
					     json{ '@id':"Book_In%20Cold%20Blood",
					           '@type':'http://s/Book',
					           'http://s/name':
                               json{ '@type':'http://www.w3.org/2001/XMLSchema#string',
								     '@value':"In Cold Blood"
								   }
					         }
				       ]
			         }
                  }.

:- end_tests(json).
