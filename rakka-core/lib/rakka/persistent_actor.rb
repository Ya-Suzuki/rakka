# frozen_string_literal: true

module Rakka
  # イベントソーシングされるアクター（集約）の定義と、それを操作するハンドル。
  #
  # サブクラスは initial_state / handle / apply_event を定義する。これらは
  # シャードRactorの中で呼ばれる。インスタンス（BankAccount.new("id")）は
  # Ractorもスレッドも持たない軽いハンドルで、コマンドをActorSystemに転送するだけ。
  # アクターの状態はシャードのメモリ上にあり、無ければイベントから復元される。
  class PersistentActor
    attr_reader :id

    class << self
      def stream_id(id)
        "#{name}-#{id}"
      end

      # シャードRactor内で handle / apply_event を呼ぶためのインスタンスを作る
      def behavior(id)
        allocate.tap { |actor| actor.instance_variable_set(:@id, id) }
      end
    end

    def initialize(id, system: nil)
      @id = id
      @system = system
    end

    def stream_id
      self.class.stream_id(id)
    end

    # サブクラスでオーバーライド
    def initial_state
      {}
    end

    # サブクラスでオーバーライド
    #   => [:persist, event, ...] | [:reject, reason] | [:noop]
    def handle(command, state)
      raise NotImplementedError
    end

    # サブクラスでオーバーライド。純粋関数であること
    def apply_event(event, state)
      raise NotImplementedError
    end

    def state
      system.state_of(self.class, id)
    end

    # メモリ上の状態を解放する（Passivation）。次のコマンドで復元される
    def stop
      system.passivate(self.class, id)
    end

    protected

    # 非同期（fire & forget）
    def send_command(command)
      system.tell(self.class, id, command)
    end

    # 同期（結果を待つ）
    def send_command_sync(command)
      system.ask(self.class, id, command)
    end

    private

    def system
      @system || Rakka.system
    end
  end
end
