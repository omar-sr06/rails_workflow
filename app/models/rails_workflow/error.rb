module RailsWorkflow
  class Error < ActiveRecord::Base
    belongs_to :parent, polymorphic: true
    has_one :context, class_name: "RailsWorkflow::Context", as: :parent
    scope :unresolved, -> { where("resolved is null or resolved = false")}

    def retry
      update_attribute(:resolved, true)

      target = context.data[:target]
      method = context.data[:method]
      args = context.data[:args]

      target.send(method, *args)

      operation = parent if parent.is_a? RailsWorkflow::Operation

      process = if operation
                  operation.process
                elsif target.is_a? RailsWorkflow::Process
                  target
                elsif parent.is_a? RailsWorkflow::Process
                  parent
                end

      if operation.present?
        operation.reload
        if operation.status == RailsWorkflow::Operation::ERROR
          operation.update_attribute(:status, RailsWorkflow::Operation::NOT_STARTED)
        end
      end

      if process.present? && can_restart_process(process)
        process.update_attribute(:status, RailsWorkflow::Process::IN_PROGRESS)
        process.start
      end

    end

    def can_restart_process process
      process.workflow_errors.
          unresolved.where.not(id: self.id).count == 0
    end

    def self.create_from exception, context

      parent = context[:parent]

      if parent.is_a? RailsWorkflow::Operation
        correct_parent = parent.becomes(RailsWorkflow::Operation)
      elsif parent.is_a? RailsWorkflow::Process
        correct_parent = parent.becomes(RailsWorkflow::Process)
      end

      error = RailsWorkflow::Error.create(
          parent_id: parent.id,
          parent_type: (correct_parent || parent).class.to_s,
          message: exception.message.first(250),
          stack_trace: exception.backtrace.join("<br/>\n")
      )

      error.create_context(data: context)

      # Workflow.config.sidekiq_enabled ?
      #     Workflow::ErrorWorker.perform_async(parent.id, parent.class.to_s) :
      #     Workflow::ErrorWorker.new.perform(parent.id, parent.class.to_s)
      RailsWorkflow::ErrorWorker.new.perform(parent.id, parent.class.to_s)
    end
  end
end