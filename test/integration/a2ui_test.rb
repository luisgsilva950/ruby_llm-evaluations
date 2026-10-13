# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../../lib/ruby_llm/evaluations"
require_relative "../postgres_helper"

class A2UITest < Minitest::Test
  E = RubyLLM::Evaluations
  ANSWER = "Returns within 30 days"

  def setup
    @sandbox = PostgresSandbox.new
  end

  def teardown
    @sandbox.close
  end

  def test_native_component_type_props_and_surface_assertions_cannot_be_hidden_by_correct_text
    cases = {
      "good" => envelope(messages),
      "wrong props" => envelope(messages(props: { text: { literalString: "Returns within 7 days" } })),
      "wrong type" => envelope(messages(type: "Image", props: { url: { literalString: "https://example.org/policy.png" } })),
      "wrong surface" => envelope(messages(surface: "other")),
      "wrong root" => envelope(messages(root: "other", components: [{ id: "other", component: { Text: { text: { literalString: ANSWER } } } }])),
      "wrong value type" => envelope(messages(props: { text: { literalString: 30 } })),
      "missing required prop" => envelope(messages(props: {})),
      "unknown prop" => envelope(messages(props: { text: { literalString: ANSWER }, html: "<script>alert(1)</script>" })),
      "invalid enum" => envelope(messages(props: { text: { literalString: ANSWER }, usageHint: "giant" })),
      "unknown component" => envelope(messages(type: "Unknown", props: {})),
      "wrong version" => envelope(messages, version: "0.9"),
      "unknown catalog" => envelope(messages(catalog: "https://example.org/unregistered.json")),
      "not a catalog ID" => envelope(messages(catalog: "standard")),
      "missing UI" => [],
      "missing instrumentation" => nil
    }
    run = E.run(suite_for(cases))
    assert_equal ["passed"] + ["failed"] * (cases.size - 1), run.case_results.map(&:status)
    run.case_results.each do |result|
      assert result.metric_results.find { |metric| metric.name == "text" }.passed
      metric = result.metric_results.find { |item| item.name == "a2ui" }
      assert_nil metric.error_details
      assert_equal result.case_id == "good" ? 1.0 : 0.0, metric.score
    end
    wrong_props = run.case_results.find { |result| result.case_id == "wrong props" }.metric_results.last
    assert_includes wrong_props.reason, "root"
    assert_includes wrong_props.reason, "literalString"
    reopened = E::Run.with_results.find(run.id)
    assert_equal run.snapshot, reopened.snapshot
    html = E::Report.new(reopened).to_html
    assert_includes html, "&lt;script&gt;"
    refute_includes html, "<script>alert(1)</script>"
  end

  def test_ordered_envelopes_updates_and_bound_defaults_use_final_state_without_hiding_invalid_evidence
    initial = messages(props: { text: { literalString: "Returns within 7 days" } }).first
    replacement = messages.first
    rendering = messages.last
    bound = messages(props: { text: { path: "/policy", literalString: ANSWER }, usageHint: "body" })
    data = { dataModelUpdate: { surfaceId: "returns", contents: [
      { key: "policy", valueString: ANSWER }, { key: "enabled", valueBoolean: false },
      { key: "details", valueMap: [{ key: "days", valueNumber: 30 }] }
    ] } }
    invalid_initial = messages(props: { text: { literalString: 30 } }).first
    cases = {
      "incremental" => envelope(initial) + envelope(JSON.generate(replacement)) + envelope(rendering),
      "bound defaults" => envelope([bound.first, data, bound.last].map { |message| JSON.generate(message) }.join("\n")),
      "JSON array" => envelope(JSON.generate(messages)),
      "invalid overwritten" => envelope([invalid_initial, replacement, rendering]),
      "deleted" => envelope(messages + [{ deleteSurface: { surfaceId: "returns" } }]),
      "recreated empty" => envelope(messages + [{ deleteSurface: { surfaceId: "returns" } }, rendering])
    }
    original = E::Data.snapshot(cases)
    run = E.run(suite_for(cases))
    assert_equal %w[passed passed passed failed failed failed], run.case_results.map(&:status)
    assert_equal original, E::Data.snapshot(cases)
    incremental = run.case_results.first
    assert_equal 3, incremental.components.size
    assert_equal "Returns within 7 days", incremental.components.first.fetch("payload").fetch("surfaceUpdate").fetch("components").first.fetch("component").fetch("Text").fetch("text").fetch("literalString")
    assert_equal true, incremental.metric_results.last.passed
  end

  def test_same_component_ids_are_surface_scoped_and_deleted_surfaces_cannot_satisfy_assertions
    expected = { surfaces: %w[returns help].to_h do |id|
      [id, { root: "root", components: { root: { type: "Text", props: { text: { literalString: ANSWER } } } } }]
    end }
    cases = {
      "both" => envelope(messages + messages(surface: "help")),
      "wrong help" => envelope(messages + messages(surface: "help", props: { text: { literalString: "Returns within 7 days" } })),
      "deleted returns" => envelope(messages + messages(surface: "help") + [{ deleteSurface: { surfaceId: "returns" } }])
    }
    run = E.run(suite_for(cases, expectations: expected))
    assert_equal %w[passed failed failed], run.case_results.map(&:status)
    assert_includes run.case_results[1].metric_results.last.reason, "help"
    assert_includes run.case_results[2].metric_results.last.reason, "returns"
  end

  def test_malformed_protocol_and_unrenderable_standard_component_graphs_fail_without_stopping_later_cases
    text = messages.first.fetch(:surfaceUpdate).fetch(:components).first
    cases = {
      "malformed JSON" => envelope("{not json"),
      "empty stream" => envelope("\n"),
      "multiple actions" => envelope([messages.first.merge(messages.last)]),
      "multiple types" => envelope(messages(components: [{ id: "root", component: { Text: { text: { literalString: ANSWER } }, Image: { url: { literalString: "https://example.org/p.png" } } } }])),
      "duplicate IDs" => envelope(messages(components: [text, text])),
      "missing root" => envelope(messages(root: "missing")),
      "no render start" => envelope(messages.first),
      "dangling child" => envelope(messages(type: "Row", props: { children: { explicitList: ["missing"] } })),
      "cycle" => envelope(messages(type: "Row", props: { children: { explicitList: ["root"] } })),
      "ambiguous children" => envelope(messages(type: "Row", props: { children: { explicitList: [], template: { componentId: "root", dataBinding: "/items" } } })),
      "ambiguous data" => envelope(messages + [{ dataModelUpdate: { surfaceId: "returns", contents: [{ key: "policy", valueString: ANSWER, valueNumber: 30 }] } }]),
      "bad style" => envelope(messages(styles: { primaryColor: "red" })),
      "valid tree" => envelope(messages(type: "Row", props: { children: { explicitList: ["body"] } }, components: [
        { id: "root", component: { Row: { children: { explicitList: ["body"] } } } },
        { id: "body", component: { Text: { text: { literalString: ANSWER } } } }
      ])),
      "last valid" => envelope(messages)
    }
    run = E.run(suite_for(cases, expectations: nil))
    assert_equal ["failed"] * (cases.size - 2) + %w[passed passed], run.case_results.map(&:status)
    run.case_results.each { |result| assert_nil result.metric_results.last.error_details }
  end

  def test_custom_catalog_hash_and_json_file_validate_false_nil_arrays_styles_and_baseline_compatibility
    catalog_id = "example.org:policy-v1"
    other_catalog_id = "example.org:other-policy"
    catalog = policy_catalog
    expected = { surfaces: { returns: { catalog: catalog_id, root: "root", components: {
      root: { type: "Policy", props: { label: ANSWER, active: false, note: nil, tags: %w[return policy] } }
    } } } }
    props = { label: ANSWER, active: false, note: nil, tags: %w[return policy], "$ref" => "https://example.org/data" }
    valid = envelope(messages(type: "Policy", props: props, catalog: catalog_id, styles: { tone: "quiet" }))
    Dir.mktmpdir("a2ui-catalog-") do |directory|
      path = File.join(directory, "catalog.json")
      File.write(path, JSON.generate(catalog))
      file_check = E::Evaluators.a2ui(catalogs: { catalog_id => path, other_catalog_id => catalog })
      baseline = E.run(suite_for({ "policy" => valid }, expectations: expected, evaluator: file_check))
      assert_equal "passed", baseline.case_results.first.status
      hash_check = E::Evaluators.a2ui(catalogs: { catalog_id => catalog, other_catalog_id => catalog })
      current = E.run(suite_for({ "policy" => valid }, expectations: expected, evaluator: hash_check))
      assert_equal baseline.suite_digest, current.suite_digest
      assert_equal baseline.id, current.previous.id

      cases = {
        "good" => valid,
        "wrong false" => envelope(messages(type: "Policy", props: props.merge(active: true), catalog: catalog_id)),
        "missing nil" => envelope(messages(type: "Policy", props: props.except(:note), catalog: catalog_id)),
        "wrong array" => envelope(messages(type: "Policy", props: props.merge(tags: %w[policy return]), catalog: catalog_id)),
        "invalid ref value" => envelope(messages(type: "Policy", props: props.merge(tags: ["unsupported"]), catalog: catalog_id)),
        "wrong catalog" => envelope(messages(type: "Policy", props: props, catalog: other_catalog_id)),
        "wrong style" => envelope(messages(type: "Policy", props: props, catalog: catalog_id, styles: { tone: "red" }))
      }
      run = E.run(suite_for(cases, expectations: expected, evaluator: hash_check))
      assert_equal %w[passed failed failed failed failed failed failed], run.case_results.map(&:status)
      assert_nil run.case_results.first.metric_results.last.error_details

      catalog[:components][:Policy][:properties][:label][:const] = "Returns within 7 days"
      File.write(path, JSON.generate(catalog))
      unchanged = E.run(suite_for({ "policy" => valid }, expectations: expected, evaluator: file_check))
      assert_equal "passed", unchanged.case_results.first.status
      updated = E::Evaluators.a2ui(catalogs: { catalog_id => path, other_catalog_id => catalog })
      changed = E.run(suite_for({ "policy" => valid }, expectations: expected, evaluator: updated))
      assert_equal "failed", changed.case_results.first.status
      refute_equal unchanged.suite_digest, changed.suite_digest
      assert_nil changed.previous
      assert_equal "passed", E::Run.find(baseline.id).case_results.first.status
    end
  end

  def test_invalid_assertions_catalog_schemas_and_remote_references_are_definition_errors
    called = false
    agent = ->(_) { called = true }
    assert_raises(E::DefinitionError) do
      E.define("invalid assertions", agent: agent) do
        question "render", minimum_scores: { a2ui: 1.0 }, metadata: { a2ui: { surfaces: { returns: { componentz: {} } } } }
      end
    end
    refute called
    assert_raises(ArgumentError) { E::Evaluators.a2ui(version: "0.9") }
    assert_raises(ArgumentError) { E::Evaluators.a2ui(catalogs: { E::A2UI::Catalogs::STANDARD_ID => policy_catalog }) }
    [ { "$ref" => "https://example.org/remote-schema" }, { "$ref" => "#/$defs/missing" }, { "type" => 42 } ].each do |schema|
      assert_raises(ArgumentError) do
        E::Evaluators.a2ui(catalogs: { "example.org:invalid" => { components: { Invalid: schema }, styles: {} } })
      end
    end
  end

  private

  def envelope(payload, version: "0.8")
    [{ protocol: "a2ui", version: version, payload: payload }]
  end

  def messages(type: "Text", props: { text: { literalString: ANSWER } }, surface: "returns", root: "root", components: nil, catalog: nil, styles: nil)
    components ||= [{ id: "root", component: { type => props } }]
    start = { surfaceId: surface, root: root }
    start[:catalogId] = catalog if catalog
    start[:styles] = styles if styles
    [{ surfaceUpdate: { surfaceId: surface, components: components } }, { beginRendering: start }]
  end

  def suite_for(cases, expectations: { surfaces: { returns: { catalog: :standard, root: "root", components: {
    root: { type: "Text", props: { text: { literalString: ANSWER } } }
  } } } }, evaluator: nil)
    agent = ->(input) { E::Response.new(output: ANSWER, components: cases.fetch(input)) }
    E.define("Native A2UI", agent: agent, agent_name: "PolicyAgent") do
      evaluate :text, using: E::Evaluators.exact_match
      evaluate :a2ui, using: evaluator if evaluator
      cases.each_key do |id|
        question id, expected_answer: ANSWER, minimum_scores: { text: 1.0, a2ui: 1.0 },
                     metadata: expectations ? { a2ui: expectations } : {}
      end
    end
  end

  def policy_catalog
    { components: { Policy: {
      type: "object", additionalProperties: false,
      "$defs" => { tag: { type: "string", enum: %w[return policy] } },
      properties: { label: { type: "string" }, active: { type: "boolean" }, note: { type: %w[string null] },
        tags: { type: "array", items: { "$ref" => "#/$defs/tag" } }, "$ref" => { type: "string" } },
      required: %w[label active tags]
    } }, styles: { tone: { type: "string", enum: %w[quiet loud] } } }
  end
end
