class ActivityController < ApplicationController
  def index
    authorize! :view_activity

    with_tenant_scope do
      @kinds = ActivityEvent::KINDS
      @kind = params[:kind].presence_in(@kinds)
      @page = [ params[:page].to_i, 1 ].max
      @per_page = 60

      scope = ActivityEvent.all
      scope = scope.where(kind: @kind) if @kind
      @total = scope.count
      @events = scope.newest_first.includes(:lead, :pixel)
                     .offset((@page - 1) * @per_page).limit(@per_page)
    end
  end
end
