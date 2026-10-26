"""Saved auto modes react to intent edits, never current spell consumption."""
import pytest
from test_party_dashboard import dashboard
from test_party_planner import lua
from test_party_plan_io import plans


@pytest.mark.parametrize('mode', ['smart', 'long'])
def test_automatic_modes_reorder_adds_and_keep_mode_after_removal(dashboard, mode):
    dashboard.globals().mode = mode
    assert dashboard.execute(r'''
      local s=snapshot();source(s,'SHORT','A',12,'s',2);source(s,'LONG','A',600,'l',2)
      setup(s);U.SortOrder(mode);assert(U.IsOrderMode(mode))
      U.ToggleCell(findrow('SHORT'),'A');U.ToggleCell(findrow('LONG'),'A')
      assert(U.preset.requests[1].group=='LONG' and U.preset.requests[2].group=='SHORT')
      U.ToggleCell(findrow('LONG'),'A')
      return #U.preset.requests==1 and U.preset.requests[1].group=='SHORT' and U.IsOrderMode(mode)
    ''')


def test_custom_restores_manual_order_and_keeps_pins_targets_and_new_buffs(dashboard):
    assert dashboard.execute(r'''
      local s=snapshot();source(s,'SHORT','A',12,'s',3);source(s,'LONG','A',600,'l',3);source(s,'MID','A',60,'m',3)
      setup(s,{request('SHORT','A','A'),request('LONG','A','A')})
      U.SortOrder('smart');U.ToggleCell(findrow('MID'),'B')
      assert(U.preset.requests[1].group=='LONG')
      U.SortOrder('custom')
      return U.preset.requests[1].group=='SHORT' and U.preset.requests[2].group=='LONG'
        and U.preset.requests[3].group=='MID' and U.preset.requests[3].target=='B'
        and U.preset.requests[1].source=='A' and U.IsOrderMode('custom')
    ''')


def test_manual_move_selects_custom_and_survives_switch_back(dashboard):
    assert dashboard.execute(r'''
      local s=snapshot();source(s,'SHORT','A',12,'s',2);source(s,'LONG','A',600,'l',2)
      setup(s,{request('SHORT','A','A'),request('LONG','A','A')});U.SortOrder('smart')
      U.request=U.preset.requests[1];U.Move(1)
      assert(U.IsOrderMode('custom') and U.preset.requests[1].group=='SHORT')
      U.SortOrder('smart');U.SortOrder('custom')
      return U.preset.requests[1].group=='SHORT'
    ''')


def test_spending_uses_does_not_resort_and_only_skips_the_spent_cast(dashboard):
    assert dashboard.execute(r'''
      local s=snapshot();local a=source(s,'SHORT','A',12,'s',1);local b=source(s,'LONG','A',600,'l',1)
      a.fullCount=1;b.fullCount=1
      setup(s,{request('SHORT','A','A'),request('LONG','A','A')});U.SortOrder('smart')
      local original=P.SortRequests;local sorts=0
      P.SortRequests=function(...)sorts=sorts+1;return original(...)end
      s.pools.l=0;U.Refresh(false);U.SetView('order');U.Refresh(false)
      local queue=P.BuildQueue(s,U.preset.requests)
      return sorts==0 and U.preset.requests[1].group=='LONG' and U.plan.missing==1 and U.CanCast()
        and #queue==1 and queue[1].spell=='SHORT'
    ''')


def test_caster_preference_change_invalidates_automatic_order(dashboard):
    assert dashboard.execute(r'''
      local s=snapshot();source(s,'WARD','A',600,'a',1);source(s,'WARD','B',12,'b',1);source(s,'MID','A',60,'m',1)
      setup(s,{request('MID','A','A'),request('WARD','A','A')});U.SortOrder('long')
      assert(U.preset.requests[1].group=='WARD')
      U.preset.requests[1].source='B';U.Refresh(false)
      return U.preset.requests[1].group=='MID' and U.preset.requests[2].source=='B'
    ''')


def test_fresh_modes_and_existing_manual_migration_roundtrip(lua):
    assert lua.execute(r'''
      assert(P.Validate(nil).presets[1].orderMode=='smart')
      local old=P.Validate({presets={{name='Old',requests={request('S','A'),request('L','A')}}}})
      assert(old.presets[1].orderMode=='custom')
      old.presets[1].orderMode='smart';old.presets[1].requests[1].manual=2;old.presets[1].requests[2].manual=1
      local saved=P.Validate(old).presets[1];P.RestoreCustomOrder(saved)
      return saved.orderMode=='smart' and saved.requests[1].group=='L'
    ''')


def test_reference_counts_spent_prepared_copies_and_keeps_live_pools(lua):
    assert lua.execute(r'''
      local s=snapshot();source(s,'LONG','A',600,'l',0);source(s,'SHORT','A',12,'s',1)
      local mem={{res='LONG',flags=0},{res='LONG',flags=0},{res='SHORT',flags=1},{res='OTHER',flags=2}}
      s.actors.A.sprite={m_memorizedSpellsMage={getReference=function(_,level)return level==0 and mem or nil end}}
      bit=require('bit')
      EEex_Utility_IterateCPtrList=function(list,f)for _,m in ipairs(list)do
        f({m_flags=m.flags,m_spellId={get=function()return m.res end}})end end
      local full=P.OrderSnapshot(s)
      local requests={request('SHORT','A','A'),request('LONG','A','A')}
      local sorted=P.SortRequests(full,requests,'long')
      return full.pools.l==2 and s.pools.l==0 and sorted[1].group=='LONG' and P.Assign(s,requests).missing==1
    ''')


def test_reference_spontaneous_variants_share_full_capacity(lua):
    assert lua.execute(r'''
      local s=snapshot();local a=source(s,'FIRST','A',60,'level',0);local b=source(s,'SECOND','A',120,'level',0)
      a.fullCount=2;b.fullCount=2
      local full=P.OrderSnapshot(s)
      return full.pools.level==2 and P.Assign(full,{request('FIRST','A'),request('SECOND','B'),request('FIRST','B')}).missing==1
    ''')


def test_daily_item_reference_restores_capacity_without_restoring_live_charges(lua):
    assert lua.execute(r'''
      local s=snapshot();local item=source(s,'BOOTS','A',3600,'boots',0)
      item.row.kind='itm';item.row.itemResref='BOOT12';item.row.abilityIdx=0
      EEex_Resource_Demand=function()return {}end
      BfBot.Scan={_GetItemAbility=function()return {}end}
      EEex_UDToPtr=function()return 100 end
      EEex_ReadU16=function(address)return address==136 and 3 or address==134 and 2 or 0 end
      local full=P.OrderSnapshot(s)
      return full.pools.boots==2 and s.pools.boots==0 and P.Assign(s,{request('BOOTS','A')}).missing==1
    ''')


def test_export_import_preserves_mode_custom_order_and_accepts_old_format(plans):
    assert plans.execute(r'''
      local p={name='Test',orderMode='smart',requests={request('L','A','B'),request('S','B','A')}}
      p.requests[1].manual=2;p.requests[2].manual=1
      local copy=assert(I.Decode(assert(I.Encode(p))))
      assert(copy.orderMode=='smart' and copy.requests[1].manual==2 and copy.requests[2].source=='A')
      local old=assert(I.Decode('BUFFBOT-PARTY-PLAN\t1\nN\t41\nR\t53\t41\t\t\t1\n'))
      return old.orderMode=='custom' and old.requests[1].manual==1
    ''')


def test_undo_restores_mode_even_when_order_was_already_sorted(dashboard):
    assert dashboard.execute(r'''
      local s=snapshot();source(s,'LONG','A',600,'l',1);source(s,'SHORT','A',12,'s',1)
      setup(s,{request('LONG','A'),request('SHORT','A')});U.SortOrder('smart')
      assert(U.IsOrderMode('smart') and U.CanUndoOrder());U.UndoOrder()
      return U.IsOrderMode('custom') and U.preset.requests[1].group=='LONG'
    ''')
