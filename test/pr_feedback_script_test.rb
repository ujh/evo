require 'minitest/autorun'
require_relative 'fake_gh'

# Runs scripts/pr-feedback.sh end to end against a fake gh.
class PrFeedbackScriptTest < Minitest::Test
  include FakeGh

  def review(id, state, body)
    { 'id' => id, 'user' => { 'login' => 'reviewer' }, 'state' => state, 'body' => body }
  end

  def feedback(api)
    out, err, status = run_with_fake_gh('pr-feedback.sh', 'https://github.com/ujh/evo/pull/7', api: api)
    assert_equal 0, status, err
    out
  end

  def test_lists_reviews_with_text_or_a_change_request
    out = feedback('pulls_reviews' => [review(1, 'CHANGES_REQUESTED', ''), review(2, 'COMMENTED', ''),
                                       review(3, 'APPROVED', 'Looks good')])
    assert_includes out, '- [1] reviewer CHANGES_REQUESTED: '
    assert_includes out, '- [3] reviewer APPROVED: Looks good'
    refute_includes out, '[2]'
  end

  def test_marks_inline_replies_and_shows_their_location
    comments = [
      { 'id' => 5, 'in_reply_to_id' => nil, 'user' => { 'login' => 'reviewer' }, 'path' => 'a.rb', 'line' => 3, 'body' => 'Why?' },
      { 'id' => 6, 'in_reply_to_id' => 5, 'user' => { 'login' => 'author' }, 'path' => 'a.rb', 'line' => nil,
        'original_line' => 3, 'body' => 'Because' }
    ]
    out = feedback('pulls_comments' => comments)
    assert_includes out, '- [5] reviewer a.rb:3: Why?'
    assert_includes out, '- [6] reply to 5 author a.rb:3: Because'
  end

  def test_lists_top_level_comments_and_reply_commands
    out = feedback('issues_comments' => [{ 'id' => 9, 'user' => { 'login' => 'someone' }, 'body' => 'Ping' }])
    assert_includes out, '- [9] someone: Ping'
    assert_includes out, 'gh pr comment 7'
    assert_includes out, 'repos/{owner}/{repo}/pulls/7/comments -F in_reply_to=ID'
  end
end
