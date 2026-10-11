# frozen_string_literal: true

RubyLLM::Evaluations::Engine.routes.draw do
  mount RubyLLM::Evaluations::Dashboard.new => "/"
end
