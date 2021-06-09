:- module('document/instance', [
              refute_instance/2,
              refute_instance_schema/2
          ]).

/*
 * Introconversion between JSON-LD and a schema language.
 *
 */

:- use_module(core(util)).
:- use_module(core(util/xsd_parser)).
:- use_module(core(triple)).
:- use_module(core(transaction)).

:- use_module(schema).

:- use_module(library(http/json)).
:- use_module(library(aggregate)).


is_rdf_list_(_Instance, Type) :-
    global_prefix_expand(rdf:nil, Type),
    !.
is_rdf_list_(Instance, Type) :-
    xrdf(Instance, Type, rdf:first, _Car),
    xrdf(Instance, Type, rdf:rest, Cdr),
    is_rdf_list_(Instance, Cdr).

is_rdf_list(Validation_Object, Type) :-
    database_instance(Validation_Object, Instance),
    is_rdf_list_(Instance, Type).

% This looks dubious
is_instance(_Validation_Object, _^^T,T) :-
    !.
is_instance(_Validation_Object, _@_, T) :-
    global_prefix_expand(rdf:literal,T),
    !.
is_instance(Validation_Object, X, C) :-
    database_instance(Validation_Object, Instance),
    xrdf(Instance, X, rdf:type, Class),
    is_simple_class(Validation_Object, Class),
    class_subsumed(Validation_Object, Class,C),
    !.

instance_of(Validation_Object, X, C) :-
    database_instance(Validation_Object, Instance),
    xrdf(Instance, X,rdf:type,C).

array_object(Validation_Object, S,I,O) :-
    database_instance(Validation_Object, Instance),
    xrdf(Instance, S,rdf:type,sys:'Array_Object'),
    % cardinality one
    findall(t(S,index,I),
            xrdf(Instance, S,sys:index,I),
            [t(S,index,I)]),
    % cardinality one
    findall(t(S,object,O),
            xrdf(Instance, S,sys:object,O),
            [t(S,object,O)]).

member_list_(Instance, O,L) :-
    xrdf(Instance, L, rdf:first, O).
member_list_(Instance, O,L) :-
    xrdf(Instance, L, rdf:rest, Cdr),
    member_list_(Instance,O,Cdr).

member_list(Validation_Object, O, L) :-
    database_instance(Validation_Object, Instance),
    member_list_(Instance, O, L).

card_count(Validation_Object, S,P,O,N) :-
    % choose as existential anything free
    database_instance(Validation_Object, Instance),
    aggregate(count,[S,P,O]^xrdf(Instance,S,P,O),N).

refute_cardinality_(class(C),Validation_Object,S,P,Witness) :-
    \+ card_count(Validation_Object, S,P,_,1),
    Witness = witness{ '@type': instance_not_cardinality_one,
                       class: C,
                       predicate: P
                     }.
refute_cardinality_(base_class(C),Validation_Object,S,P,Witness) :-
    \+ card_count(Validation_Object, S,P,_,1),
    Witness = witness{ '@type': instance_not_cardinality_one,
                       class: C,
                       predicate: P
                     }.
refute_cardinality_(enum(C,_),Validation_Object, S,P,Witness) :-
    \+ card_count(Validation_Object, S,P,_,1),
    Witness = witness{ '@type': instance_not_cardinality_one,
                       class: C,
                       predicate: P
                     }.
refute_cardinality_(tagged_union(C,_),Validation_Object,S,P,Witness) :-
    \+ card_count(Validation_Object,S,P,_,1),
    Witness = witness{ '@type': instance_not_cardinality_one,
                       class: C,
                       predicate: P
                     }.
refute_cardinality_(not_tagged_union(C,_),Validation_Object,S,P,Witness) :-
    \+ card_count(Validation_Object,S,P,_,0),
    Witness = witness{ '@type': instance_not_cardinality_zero,
                       class: C,
                       predicate: P
                     }.
refute_cardinality_(set(_C),_Validation_Object,_S,_P,_Witness) :-
    % no bad cardinality possible
    fail.
refute_cardinality_(array(_C),_Validation_Object,_S,_P,_Witness) :-
    % no bad cardinality possible
    fail.
refute_cardinality_(list(C),Validation_Object,S,P,Witness) :-
    \+ card_count(Validation_Object,S,P,_,1),
    Witness = witness{ '@type': instance_not_cardinality_one,
                       class: C,
                       predicate: P
                     }.
refute_cardinality_(optional(C),Validation_Object,S,P,Witness) :-
    card_count(Validation_Object,S,P,_,N),
    (   \+ memberchk(N, [0,1])
    ->  range_term_list(Validation_Object,S,P,L),
        Witness = witness{ '@type': instance_has_wrong_cardinality,
                           class: C,
                           instance: S,
                           predicate: P,
                           cardinality: N,
                           object_list: L
                         }
    ).
refute_cardinality_(cardinality(C,N),Validation_Object,S,P,Witness) :-
    \+ card_count(Validation_Object,S,P,_,N),
    range_term_list(Validation_Object,S,P,L),
    Witness = witness{ '@type': instance_has_wrong_cardinality,
                       class: C,
                       instance: S,
                       object_list: L,
                       predicate: P,
                       cardinality: N
                     }.

internal_simple_json(X^^_, X) :-
    (   string(X)
    ;   atom(X)
    ),
    !.
internal_simple_json(X, X) :-
    atom(X),
    !.
internal_simple_json(D^^T, X) :-
    typecast(D^^T, 'http://www.w3.org/2001/XMLSchema#string', [], X).

range_term_list(Validation_Object, S, P, L) :-
    database_instance(Validation_Object, Instance),
    findall(J,
            (   xrdf(Instance, S,P,O),
                internal_simple_json(O, J)
            ),
            L).

refute_cardinality(Validation_Object,S,P,C,Witness) :-
    type_descriptor(Validation_Object, C, tagged_union(TU,TC)),
    class_predicate_type(Validation_Object, C, P, _),
    !,
    (   refute_cardinality_(tagged_union(TU,TC),Validation_Object,S,P,Witness)
    ;   class_predicate_type(Validation_Object,C,Q,tagged_union(TU,R)),
        P \= Q,
        refute_cardinality_(not_tagged_union(TU,R),Validation_Object,S,Q,Witness)
    ).
refute_cardinality(Validation_Object,S,_,C,Witness) :-
    class_predicate_type(Validation_Object, C,P,Desc),
    refute_cardinality_(Desc,Validation_Object,S,P,Witness).

refute_built_in_value(Validation_Object, rdf:type,O,Witness) :-
    refute_class(Validation_Object, O,Witness).
refute_built_in_value(_Validation_Object, rdfs:comment,O@L,Witness) :-
    \+ (string(O),
        atom(L)),
    format(atom(Atom), '~q@~q', [O,L]),
    Witness = witness{
                  '@type': comment_not_valid,
                  comment: Atom
              }.
refute_built_in_value(_Validation_Object, rdfs:label,O@L,Witness) :-
    \+ (string(O),
        atom(L)),
    format(atom(Atom), '~q@~q', [O,L]),
    Witness = witness{
                  '@type': comment_not_valid,
                  comment: Atom
              }.

subject_changed(Validation_Object, Subject) :-
    database_instance(Validation_Object, Instance),
    distinct(Subject,(   xrdf_deleted(Instance, Subject,_,_)
                     ;   xrdf_added(Instance, Subject,_,_))).

subject_inserted(Validation_Object, Subject) :-
    database_instance(Validation_Object, Instance),
    xrdf_added(Instance, Subject,rdf:type,_),
    \+ xrdf_deleted(Instance, Subject,_,_),
    !.

subject_updated(Validation_Object, Subject) :-
    database_instance(Validation_Object, Instance),
    distinct(Subject,(xrdf_deleted(Instance, Subject,_,_),
                      xrdf_added(Instance, Subject,_,_))).

subject_deleted(Validation_Object, Subject) :-
    database_instance(Validation_Object, Instance),
    xrdf_deleted(Instance, Subject,rdf:type,_).

subject_predicate_changed(Validation_Object, Subject,Predicate) :-
    database_instance(Validation_Object, Instance),
    distinct(Subject-Predicate,(   xrdf_deleted(Instance, Subject,Predicate,_)
                               ;   xrdf_added(Instance, Subject,Predicate,_))).

subject_predicate_updated(Validation_Object, Subject,Predicate) :-
    database_instance(Validation_Object, Instance),
    distinct(Subject-Predicate,(xrdf_deleted(Instance, Subject,Predicate,_),
                                xrdf_added(Instance, Subject,Predicate,_))).

refute_key(Validation_Object, Subject,Predicate,Class,Witness) :-
    key_descriptor(Validation_Object, Class,Desc),
    refute_key_(Desc,Validation_Object,Subject,Predicate,Witness).

refute_key_(lexical(_,Fields),Validation_Object,Subject,Predicate,Witness) :-
    subject_predicate_updated(Validation_Object,Subject,Predicate),
    member(Predicate,Fields),
    Witness = json{ '@type' : lexical_key_changed,
                    subject: Subject }.
refute_key_(value_hash(_),Validation_Object,Subject,Predicate,Witness) :-
    subject_predicate_updated(Validation_Object,Subject,Predicate),
    Witness = json{ '@type' : value_key_changed,
                    subject: Subject }.
refute_key_(hash(_,Fields),Validation_Object,Subject,Predicate,Witness) :-
    subject_predicate_updated(Validation_Object,Subject,Predicate),
    member(Predicate,Fields),
    Witness = json{ '@type' : hash_key_changed,
                    subject: Subject }.

refute_subject_deletion(Validation_Object, Subject,Witness) :-
    subject_deleted(Validation_Object, Subject),
    database_instance(Validation_Object, Instance),
    xrdf(Instance,Subject,Predicate,Object),
    Witness = json{ '@type' : entire_object_not_deleted,
                    subject : Subject,
                    predicate : Predicate,
                    object : Object }.

refute_subject_type_change(Validation_Object,Subject,Witness) :-
    database_instance(Validation_Object, Instance),
    xrdf_added(Instance, Subject,rdf:type,Old_Type),
    xrdf_deleted(Instance, Subject,rdf:type,New_Type),
    Witness = json{ '@type' : subject_type_has_changed,
                    old_type : Old_Type,
                    new_type : New_Type}.

refute_object_type(_,Class,Subject,Predicate,Witness) :-
    is_array_type(Class),
    !,
    \+ (   global_prefix_expand(sys:index, SYS_Index),
           global_prefix_expand(sys:value, SYS_Value),
           global_prefix_expand(rdf:type, RDF_Type),
           memberchk(Predicate, [SYS_Index, SYS_Value, RDF_Type])),
    Witness = json{ '@type' : invalid_array_type,
                    subject: Subject,
                    class: Class }.
refute_object_type(_,Class,Subject,Predicate,Witness) :-
    is_list_type(Class),
    !,
    \+ (   global_prefix_expand(rdf:first, RDF_First),
           global_prefix_expand(rdf:rest, RDF_Rest),
           global_prefix_expand(rdf:type, RDF_Type),
           memberchk(Predicate, [RDF_First, RDF_Rest, RDF_Type])),
    Witness = json{ '@type' : invalid_list_type,
                    subject: Subject,
                    class: Class }.
refute_object_type(Validation_Object, Class,Subject,Predicate,Witness) :-
    database_instance(Validation_Object, Instance),
    (   class_predicate_type(Validation_Object, Class,Predicate,Type)
    ->  xrdf_added(Instance, Subject,Predicate,Object),
        refute_object_type_(Type,Validation_Object,Object,Witness)
    ;   Witness = json{ '@type' : invalid_predicate,
                        class: Class,
                        predicate: Predicate,
                        subject: Subject }
    ).

refute_object_type_(base_type(C),_Validation_Object,Object,Witness) :-
    refute_basetype_elt(Object,C,Witness).
refute_object_type_(class(C),Validation_Object,Object,Witness) :-
    \+ is_instance(Validation_Object,Object,C),
    Witness = witness{ '@type': instance_not_of_class,
                       class: C,
                       instance: Object }.
refute_object_type_(set(C),Validation_Object,Object,Witness) :-
    \+ is_instance(Validation_Object,Object,C),
    Witness = witness{ '@type': instance_not_of_class,
                       class: C,
                       instance: Object }.
refute_object_type_(cardinality(C),Validation_Object,Object,Witness) :-
    \+ is_instance(Validation_Object,Object,C),
    Witness = witness{ '@type': instance_not_of_class,
                       class: C,
                       instance: Object }.
refute_object_type_(optional(C),Validation_Object,Object,Witness) :-
    \+ is_instance(Validation_Object,Object,C),
    Witness = witness{ '@type': instance_not_of_class,
                       class: C,
                       instance: Object }.
refute_object_type_(array(C),Validation_Object,Object,Witness) :-
    database_instance(Validation_Object, Instance),
    xrdf_added(Instance,Object,sys:value,O),
    \+ is_instance(Validation_Object,O,C),
    Witness = witness{
                  '@type': array_instance_not_of_class,
                  class: C,
                  instance: O,
                  array: Object
              }.
refute_object_type_(list(C),Validation_Object,Object,Witness) :-
    (   \+ is_rdf_list(Validation_Object, Object)
    ->  Witness = witness{'@type':not_a_valid_list,
                          class:C,
                          list:Object}
    ;   member_list(Validation_Object, Elt,Object),
        \+ is_instance(Validation_Object,Elt,C),
        Witness = witness{
                      '@type': list_element_of_wrong_type,
                      class: C,
                      object: Elt,
                      list: Object
                  }
    ).

refute_built_in(Validation_Object,Subject,Predicate,Witness) :-
    database_instance(Validation_Object, Instance),
    xrdf_added(Instance,Subject,Predicate,Value),
    refute_built_in_value(Validation_Object,Predicate,Value,Witness).


refute_typed_subject(Validation_Object,Subject,Class,Witness) :-
    subject_predicate_changed(Validation_Object,Subject,Predicate),
    % We also need to check arrays / lists for coherence here?
    (   is_built_in(Predicate)
    ->  refute_built_in(Validation_Object,Subject,Predicate,Witness)
    ;   refute_subject_deletion(Validation_Object,Subject,Witness)
    ;   refute_subject_type_change(Validation_Object,Subject,Witness)
    ;   refute_key(Validation_Object,Subject,Predicate,Class,Witness)
        % NOTE: Perhaps this can be more intelligence predicates
    ;   refute_cardinality(Validation_Object,Subject,Predicate,Class,Witness)
    ;   refute_object_type(Validation_Object,Class,Subject,Predicate,Witness)
    ).

refute_subject(Validation_Object,Subject,_Witness) :-
    database_instance(Validation_Object, Instance),
    \+ xrdf(Instance, Subject, _, _),
    !,
    fail.
refute_subject(Validation_Object,Subject,Witness) :-
    (   instance_of(Validation_Object, Subject, Class)
    ->  refute_typed_subject(Validation_Object, Subject, Class, Witness)
    ;   Witness = witness{
                      '@type': subject_has_no_type,
                      subject: Subject
                  }).

refute_instance(Validation_Object, Witness) :-
    subject_changed(Validation_Object, Subject),
    refute_subject(Validation_Object,Subject,Witness).

refute_instance_schema(Validation_Object, Witness) :-
    refute_schema(Validation_Object,Witness).
refute_instance_schema(Validation_Object, Witness) :-
    database_instance(Validation_Object, Instance),
    distinct(Subject,
             xrdf(Instance, Subject, _, _)),
    refute_subject(Validation_Object,Subject,Witness).

/*
insert_document(JSON,JSON_ID) :-
    json_elaborate(JSON,Elaborated),
    json_jsonid(Elaborated,JSON_ID),
    (   json_instance:t(JSON_ID, rdf:type, _)
    ->  throw(error(document_alread_exists(JSON_ID)))
    ;   true),
    forall(
        json_triple_(Elaborated,Triple),
        insert_triple(Triple)
    ),

    forall(
        json_triple_(Elaborated,t(X,Y,Z)),
        (   refute_insert(X,Y,Z,Witness)
        ->  throw(error(insert_failure(Witness)))
        ;   true)
    ),
    commit.

delete_document(JSON) :-
    json_elaborate(JSON,Elaborated),
    json_jsonid(Elaborated,JSON_ID),
    (   json_instance:t(JSON_ID, rdf:type, _)
    ->  throw(error(document_alread_exists(JSON_ID)))
    ;   true),
    forall(
        json_triple_(Elaborated,Triple),
        delete_triple(Triple)
    ),

    forall(
        json_triple_(Elaborated,t(X,Y,Z)),
        (   refute_insert(X,Y,Z,Witness)
        ->  throw(error(insert_failure(Witness)))
        ;   true)
    ),
    commit.
*/

%%%%%%%%%%%%%%%%%%%%%%
%%  BASETYPES ONLY  %%
%%%%%%%%%%%%%%%%%%%%%%

/*
 * refute_basetype_elt(+Literal,+Type,-Reason)
 */
refute_basetype_elt(L,T,R) :-
    (   L = _^^T2,
        \+ basetype_subsumption_of(T,T2)
    ->  R = json{
                '@type' : 'vio:DataTypeSubsumptionViolation',
                'vio:message' : 'Could not subsume type1:required_type with type2:found_type',
			    'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : T},
			    'vio:parent_type' : json{ '@type' : 'xsd:string', '@value' : T2}
            }
    ;   refute_basetype_elt_(T,L,R)
    ).

refute_basetype_elt_('http://www.w3.org/1999/02/22-rdf-syntax-ns#langString',S@L,Reason) :-
    (   \+ (atom(S) ; string(S)),
        term_to_atom(S@L,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
			         'vio:message' : 'Expected atom or string for language value, found term.',
			         'vio:literal' : json{ '@value' : A, '@type' : 'xsd:anySimpleType'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/1999/02/22-rdf-syntax-ns#langString',S@L,Reason) :-
    (   \+ atom(L),
        term_to_atom(S@L,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
			         'vio:message' : 'Expected atom in language section, found term.',
			         'vio:literal' : json{ '@value' : A, '@type' : 'xsd:anySimpleType'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#string',S@L,Reason) :-
    (   \+ atom(L),
        term_to_atom(S@L,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
			         'vio:message' : 'Expected atom in language section, found term.',
			         'vio:literal' : json{ '@value' : A, '@type' : 'xsd:anySimpleType'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#string',S@L,Reason) :-
    (   \+ (atom(S) ; string(S)),
        term_to_atom(S@L,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
			         'vio:message' : 'Expected atom or string for language value, found term.',
			         'vio:literal' : json{ '@value' : A, '@type' : 'xsd:anySimpleType'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#string',S^^_,Reason) :-
    (   \+ (atom(S) ; string(S)),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
			         'vio:message' : 'Expected atom, found term as element.',
			         'vio:literal' : json{ '@value' : A, '@type' : 'xsd:anySimpleType'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#string',S^^T,Reason) :-
    (   \+ atom(T),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
			         'vio:message' : 'Expected atom, found term as type.',
			         'vio:literal' : json{ '@value' : A, '@type' : 'xsd:anySimpleType'}
                 }
    ).
refute_basetype_elt_('http://terminusdb.com/schema/xdd#coordinatePolygon',S^^_, Reason) :-
    (   \+ is_coordinate_polygon(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed coordinate polygon',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xdd:coordinatePolygon'}
                 }
    ).
refute_basetype_elt_('http://terminusdb.com/schema/xdd#coordinatePolyline',S^^_, Reason) :-
    (   \+ is_coordinate_polygon(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed coordinate polyline',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xdd:coordinatePolyline'}
                 }
    ).
refute_basetype_elt_('http://terminusdb.com/schema/xdd#coordinate',S^^_, Reason) :-
    (   \+ is_point(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed coordinate',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xdd:coordinate'}
                 }
    ).
refute_basetype_elt_('http://terminusdb.com/schema/xdd#dateRange',S^^_, Reason) :-
    (   \+ is_date_range(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed dateRange',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xdd:dateRange'}
                 }
    ).
refute_basetype_elt_('http://terminusdb.com/schema/xdd#integerRange',S^^_, Reason) :-
    (   \+ is_integer_range(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed integerRange',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xdd:integerRange'}
                 }
    ).
refute_basetype_elt_('http://terminusdb.com/schema/xdd#decimalRange',S^^_, Reason) :-
    (   \+ is_decimal_range(S),
        term_to_atom(S,A)
	->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed decimalRange',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xdd:decimalRange'}
                 }
    ).
refute_basetype_elt_('http://terminusdb.com/schema/xdd#gYearRange',S^^_, Reason) :-
    (   \+ is_gyear_range(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed gYearRange',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xdd:gYearRange'}
                 }
    ).
refute_basetype_elt_('http://terminusdb.com/schema/xdd#url',S^^_, Reason) :-
    (   \+ (atom_codes(S,C), phrase(xsd_parser:url,C,[])),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a valid URL',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xdd:url'}
                 }
    ).
refute_basetype_elt_('http://terminusdb.com/schema/xdd#email',S^^_, Reason) :-
    (   \+ (atom_codes(S,C), phrase(xsd_parser:email,C,[])),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a valid email address',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xdd:email'}
                 }
    ).
refute_basetype_elt_('http://terminusdb.com/schema/xdd#json',S^^_, Reason) :-
    (   \+ (catch(atom_json_dict(S,_,[]),_,fail)),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a valid json object',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xdd:json'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#boolean',S^^_,Reason) :-
    (   \+ is_boolean(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed boolean.',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:boolean'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#decimal',S^^_,Reason) :-
    (   \+ number(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed decimal.',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:decimal'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#integer',S^^_,Reason) :-
    (   \+ integer(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed integer.',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:integer'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#double',S^^_,Reason) :-
    (   \+ float(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed double.',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:double'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#float',S^^_,Reason) :-
    (   \+ float(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed float.',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:float'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#time',S^^_,Reason) :-
    (   \+ is_time(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:time',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:time'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#date',S^^_,Reason) :-
    (   \+ is_date(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:date.',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:date'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#dateTime', S^^_,Reason) :-
    (   \+ is_date_time(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:dateTime : parameter out of range.',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:dateTime'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#gYear',S^^_,Reason) :-
    (   \+ is_gyear(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:gYear',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:gYear'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#gMonth',S^^_,Reason) :-
    (   \+ is_gmonth(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:Month',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:gMonth'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#gDay',S^^_,Reason) :-
    (   \+ is_gday(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:gMonth',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:gMonth'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#gYearMonth',S^^_,Reason) :-
    (   \+ is_gyear_month(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:gYearMonth',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:gYearMonth'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#gMonthDay',S^^_,Reason) :-
    (   \+ is_gmonth_day(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:gYearMonth',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:gMonthDay'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#duration',S^^_,Reason) :-
    (   \+ is_duration(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:duration',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:duration'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#byte',S^^_,Reason) :-
    (   \+ is_byte(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:byte',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:byte'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#short',S^^_,Reason) :-
    (   \+ is_short(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:short',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:short'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#int',S^^_,Reason) :-
    (   \+ is_int(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:int',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:int'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#long',S^^_,Reason) :-
    (   \+ is_long(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:long',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:long'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#unsignedByte',S^^_,Reason) :-
    (   \+ is_unsigned_byte(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:unsignedByte',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:unsignedByte'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#unsignedShort',S^^_,Reason) :-
    (   \+ is_unsigned_short(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:unsignedShort',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:unsignedShort'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#unsignedInt',S^^_,Reason) :-
    (   \+ is_unsigned_int(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:unsignedInt',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:unsignedInt'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#unsignedLong',S^^_,Reason) :-
    (   \+ is_unsigned_long(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:unsignedLong',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:unsignedLong'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#positiveInteger',S^^_,Reason) :-
    (   \+ is_positive_integer(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:positiveInteger',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:positiveInteger'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#nonNegativeInteger',S^^_,Reason) :-
    (   \+ is_nonnegative_integer(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:nonNegativeInteger',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
	                 'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:nonNegativeInteger'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#negativeInteger',S^^_,Reason) :-
    (   \+ is_negative_integer(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:negativeInteger',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:negativeInteger'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#nonPositiveInteger',S^^_,Reason) :-
    (   \+ is_nonpositive_integer(S),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:nonPositiveInteger',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:nonPositiveInteger'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#base64Binary',S^^_,Reason) :-
    (   \+ (atom_codes(S,C), phrase(xsd_parser:base64Binary,C,[])),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:base64Binary',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:base64Binary'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#hexBinary',S^^_,Reason) :-
    (   \+ (atom_codes(S,C), phrase(xsd_parser:hexBinary,C,[])),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:hexBinary',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:hexBinary'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#anyURI',S^^_,Reason) :-
    (   \+ uri_components(S,_),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:anyUri',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:anyURI'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#language',S^^_,Reason) :-
    (   \+ (atom_codes(S,C), phrase(xsd_parser:language, C, [])),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:language',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:language'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#normalizedString',S^^_,Reason) :-
    (   \+  (atom_codes(S,C), phrase(xsd_parser:normalizedString,C, [])),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:normalizedString',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:normalizedString'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#token',S^^_,Reason) :-
    (   \+  (atom_codes(S,C), phrase(xsd_parser:normalizedString,C, [])),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:token',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:token'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#NMTOKEN',S^^_,Reason) :-
    (   \+  (atom_codes(S,C), phrase(xsd_parser:nmtoken,C, [])),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:NMTOKEN',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:NMTOKEN'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#Name',S^^_,Reason) :-
    (   \+  (atom_codes(S,C), phrase(xsd_parser:name,C, [])),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:Name',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:Name'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/2001/XMLSchema#NCName',S^^_,Reason) :-
    (   \+  (atom_codes(S,C), phrase(xsd_parser:ncname,C, [])),
        term_to_atom(S,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed xsd:NCName',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'xsd:NCName'}
                 }
    ).
refute_basetype_elt_('http://www.w3.org/1999/02/22-rdf-syntax-ns#PlainLiteral',T,Reason) :-
    (   \+ (atom(T) ; string(T)),
        term_to_atom(T,A)
    ->  Reason = json{
                     '@type' : 'vio:ViolationWithDatatypeObject',
                     'vio:message' : 'Not a well formed rdf:PlainLiteral',
                     'vio:literal' : json{ '@type' : 'xsd:anySimpleType', '@value' : A},
                     'vio:base_type' : json{ '@type' : 'xsd:string', '@value' : 'rdf:PlainLiteral'}
                 }
    ).

:- begin_tests(json_instance).

/*

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
                "@class" : "xsd:string" } }
').

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

test(simple_class_with_set,
     [
         setup(
             (
                 setup_temp_store(State),
                 test_document_label_descriptor(Desc),
                 write_schema1(Desc)
             )),

         cleanup(
             teardown_temp_store(State)
         )
     ]) :-

    create_context(Desc, _{author : "me", message: "yes"}, Context),
    with_transaction(
        Context,
        (   % Jim
            insert_document(
                Context,
                json{'@id' : jim,
                     '@type' : 'Person',
                     name : "jim",
                     birthdate: "1978-10-09",
                     friends : [jane]},
                _),
            insert_document(
                Context,
                json{'@id' : jane,
                     '@type' : 'Person',
                     name : "jane",
                     birthdate: "1979-11-02",
                     friends : [jim]},
                _)
        ),
        _).

test(simple_class_with_bad_required,
     [
         setup(
             (   delete_database,
                 create_database,

             % Schema
                 insert_triple(s(person, rdf:type, 'Class')),
                 insert_triple(s(person, name, xsd:string)),

             % Jim
                 insert_triple(t(jim, rdf:type, person)),
                 insert_triple(t(jim, name, "jim"^^xsd:string)),

             % Jane
                 insert_triple(t(jane, rdf:type, person)),
                 insert_triple(t(jane, name, "jane"^^xsd:string)),

                 check_and_commit
             )
         ),

         cleanup(
             delete_database
         ),
         error(subject_refutation_failure(
                   witness{'@type':instance_not_cardinality_one,
                           class:xsd:string,
                           predicate:name}),
               _)
     ]) :-
    %class_predicate_type(name, person, _5712)

    delete_triple(t(jane, name, "jane"^^xsd:string)),

    stage,

    check_and_commit.


test(simple_class_with_set_list_optional,
     [
         setup(
             (   delete_database,
                 create_database,

             % Schema
                 forall(schema1(A,B,C),
                        insert_triple(s(A,B,C))),

             % Jim
                 insert_triple(t(jim, rdf:type, employee)),
                 insert_triple(t(jim, staff_number, "12"^^xsd:string)),
                 insert_triple(t(jim, tasks, b:tasks1)),
                 insert_triple(t(b:tasks1, rdf:first, copy_stuff)),
                 insert_triple(t(b:tasks1, rdf:rest, rdf:nil)),

             % Copy stuff
                 insert_triple(t(copy_stuff, rdf:type, task)),
                 insert_triple(t(copy_stuff, name, "copy stuff"^^xsd:string)),

             % Jane
                 insert_triple(t(jane, rdf:type, employee)),
                 insert_triple(t(jane, name, "jane"^^xsd:string)),
                 insert_triple(t(jane, birthdate, "1979-11-02"^^xsd:date)),
                 insert_triple(t(jane, boss, jim)),
                 insert_triple(t(jane, friends, jim))

             )),

         cleanup(
             delete_database
         )
     ]) :-

    check_and_commit.


test(simple_class_with_bad_set,
     [
         setup(
             (   delete_database,
                 create_database,

             % Schema
                 forall(schema1(A,B,C),
                        insert_triple(s(A,B,C))),

             % Jim
                 insert_triple(t(jim, rdf:type, employee)),
                 insert_triple(t(jim, staff_number, "12"^^xsd:string)),
                 insert_triple(t(jim, tasks, b:tasks1)),
                 insert_triple(t(b:tasks1, rdf:first, copy_stuff)),
                 insert_triple(t(b:tasks1, rdf:rest, rdf:nil)),

             % Copy stuff
                 insert_triple(t(copy_stuff, rdf:type, task)),
                 insert_triple(t(copy_stuff, name, "copy stuff"^^xsd:string)),

             % Jane
                 insert_triple(t(jane, rdf:type, employee)),
                 insert_triple(t(jane, name, "jane"^^xsd:string)),
                 insert_triple(t(jane, birthdate, "1979-11-02"^^xsd:date)),
                 insert_triple(t(jane, boss, jim)),
                 insert_triple(t(jane, friends, copy_stuff))

             )),

         cleanup(
             delete_database
         ),
         error(
             subject_refutation_failure(witness{'@type':instance_not_of_class,
                                                class:person,
                                                instance:copy_stuff}),
             _)
     ]) :-

    check_and_commit.

test(simple_class_with_bad_list,
     [
         setup(
             (   delete_database,
                 create_database,

             % Schema
                 forall(schema1(A,B,C),
                        insert_triple(s(A,B,C))),

             % Jim
                 insert_triple(t(jim, rdf:type, employee)),
                 insert_triple(t(jim, staff_number, "12"^^xsd:string)),
                 insert_triple(t(jim, tasks, jane)),

             % Copy stuff
                 insert_triple(t(copy_stuff, rdf:type, task)),
                 insert_triple(t(copy_stuff, name, "copy stuff"^^xsd:string)),

             % Jane
                 insert_triple(t(jane, rdf:type, employee)),
                 insert_triple(t(jane, name, "jane"^^xsd:string)),
                 insert_triple(t(jane, birthdate, "1979-11-02"^^xsd:date)),
                 insert_triple(t(jane, boss, jim)),

                 stage

             )),

         cleanup(
             delete_database
         ),
         error(subject_refutation_failure(
                   witness{'@type':not_a_valid_list,
                           class:task,
                           list:jane}),_)
     ]) :-

    check_and_commit.

test(simple_class_with_bad_optional,
     [
         setup(
             (   delete_database,
                 create_database,

             % Schema
                 forall(schema1(A,B,C),
                        insert_triple(s(A,B,C))),

             % Jim
                 insert_triple(t(jim, rdf:type, employee)),
                 insert_triple(t(jim, staff_number, "12"^^xsd:string)),
                 insert_triple(t(jim, tasks, b:task1)),
                 insert_triple(t(b:task1, rdf:first, copy_stuff)),
                 insert_triple(t(b:task1, rdf:rest, rdf:nil)),

             % Copy stuff
                 insert_triple(t(copy_stuff, rdf:type, task)),
                 insert_triple(t(copy_stuff, name, "copy stuff"^^xsd:string)),

             % Jane
                 insert_triple(t(jane, rdf:type, employee)),
                 insert_triple(t(jane, name, "jane"^^xsd:string)),
                 insert_triple(t(jane, birthdate, "1979-11-02"^^xsd:date)),
                 insert_triple(t(jane, boss, jim)),
                 insert_triple(t(jane, boss, jane))

             )),

         cleanup(
             delete_database
         ),
         error(subject_refutation_failure(
                   witness{'@type':instance_has_wrong_cardinality,
                           cardinality:2,
                           class:employee,
                           instance:jane,
                           predicate:boss}),
               _)
     ]) :-

    check_and_commit.

test(simple_class_bad_optional,
     [
         setup(
             (   delete_database,
                 create_database,

             % Schema
                 forall(schema1(A,B,C),
                        insert_triple(s(A,B,C))),

             % Jim
                 insert_triple(t(jim, rdf:type, employee)),
                 insert_triple(t(jim, staff_number, "12")),
                 insert_triple(t(jim, tasks, rdf:nil)),

             % Copy stuff
                 insert_triple(t(copy_stuff, rdf:type, task)),
                 insert_triple(t(copy_stuff, name, "copy stuff"^^xsd:string)),

             % Jane
                 insert_triple(t(jane, rdf:type, employee)),
                 insert_triple(t(jane, name, "jane"^^xsd:string)),
                 insert_triple(t(jane, birthdate, "1979-11-02"^^xsd:date)),
                 insert_triple(t(jane, boss, jim)),
                 insert_triple(t(jane, boss, cleanup))


             )),

         setup(
             delete_database
         ),
         error(subject_refutation_failure(
                   witness{'@type':instance_has_wrong_cardinality,
                           cardinality:2,
                           class:employee,
                           instance:jane,
                           predicate:boss}),_)
     ]) :-

    check_and_commit.

test(base_type_list,
     [
         setup(
             (   delete_database,
                 create_database,

             % Schema
                 forall(schema1(A,B,C),
                        insert_triple(s(A,B,C))),

             % Jim
                 insert_triple(t(jim, rdf:type, criminal)),
                 insert_triple(t(jim, name, "jim"^^xsd:string)),
                 insert_triple(t(jim, birthdate, "1979-11-02"^^xsd:date)),
                 insert_triple(t(jim, aliases, b:aliases1)),
                 insert_triple(t(b:aliases1, rdf:first, "jimbo"^xsd:string)),
                 insert_triple(t(b:aliases1, rdf:rest, b:aliases2)),
                 insert_triple(t(b:aliases2, rdf:first, "jamesy"^xsd:string)),
                 insert_triple(t(b:aliases2, rdf:rest, rdf:nil))

             )),

         cleanup(
             delete_database
         ),
         error(subject_refutation_failure(
                   witness{'@type':list_element_of_wrong_type,
                           class:xsd:string,
                           list:b:aliases1,
                           object:"jimbo"^xsd:string}),
               _)
     ]) :-

    check_and_commit.

*/

:- end_tests(json_instance).
