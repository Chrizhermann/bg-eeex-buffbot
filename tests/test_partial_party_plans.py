"""Unavailable requests are visible and reported, without blocking other casts."""
from test_party_planner import lua
from test_party_dashboard import dashboard
from test_visual_redesign import visual
from test_completed_rest import lua as rest


def test_queue_preserves_available_order_and_does_not_count_disabled_requests(lua):
    assert lua.execute('''
      local s=snapshot();source(s,'FIRST','A',60,'a',1);source(s,'LAST','B',60,'b',1)
      local disabled=request('OFF','A');disabled.on=0
      local q,p=P.BuildQueue(s,{request('FIRST','A'),request('MISSING','B'),disabled,request('LAST','B')})
      notices={};BfBot._Display=function(m)notices[#notices+1]=m end
      P.ReportSkipped(p)
      return #q==2 and q[1].spell=='FIRST' and q[2].spell=='LAST'
        and q[2].planIndex==2 and p.missing==1 and #notices==1
        and notices[1]=='BuffBot: skipped 1 unavailable planned cast(s).'
    ''')


def test_all_unavailable_reports_count_without_creating_an_empty_run(lua):
    assert lua.execute('''
      local q,p=P.BuildQueue(snapshot(),{request('GONE','A'),request('GONE','B')})
      local notice;BfBot._Display=function(m)notice=m end;P.ReportSkipped(p)
      return q==nil and p.missing==2 and notice=='BuffBot: skipped 2 unavailable planned cast(s).'
    ''')


def test_only_an_unavailable_enabled_assignment_warns(visual):
    assert visual.execute('''
      local s=snapshot();source(s,'OK','A',60,'a',1);source(s,'EMPTY','B',60,'b',0)
      local off=request('EMPTY','A');off.on=0
      setup(s,{request('OK','A'),request('EMPTY','B'),off})
      local good=findrow('OK');assert(good.free==0 and good.total==1)
      assert(not V.UsesExhausted(bbPartyRowSelection))
      local bad=findrow('EMPTY')
      return bad.unavailable==1 and V.UsesExhausted(bbPartyRowSelection)
        and U.UsesTip(bbPartyRowSelection):find('Unavailable planned casts: 1',1,true)~=nil
    ''')


def test_gui_starts_available_casts_and_keeps_missing_requests(dashboard):
    assert dashboard.execute('''
      local s=snapshot();source(s,'OK','A',60,'a',1)
      setup(s,{request('MISSING','B'),request('OK','A')})
      local queue,notice;BfBot._Display=function(m)notice=m end
      BfBot.Exec.Start=function(q)queue=q;return true end
      U.Close=function()end;assert(U.CanCast());U.Cast()
      return #queue==1 and queue[1].spell=='OK' and #U.preset.requests==2
        and notice=='BuffBot: skipped 1 unavailable planned cast(s).'
    ''')


def test_rest_dispatch_reports_partial_plan_and_starts_once(rest):
    assert rest.execute('''
      local notice;BfBot._Display=function(m)notice=m end
      P.BuildQueue=function()return {{spell='BUFF'}},{missing=2}end
      pending();R.Tick();now=now+500;R.Tick()
      return calls==1 and R.pending==nil and notice=='BuffBot: skipped 2 unavailable planned cast(s).'
    ''')
