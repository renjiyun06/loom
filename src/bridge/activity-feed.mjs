import fs from 'node:fs';
import path from 'node:path';
import { replaceFileSync } from './atomic-files.mjs';

const uuid = /^[a-f0-9-]{36}$/i;

// A transient UI projection. SQLite remains the source for both recent and older rows.
export class ActivityFeed {
  constructor(ipc, store) {
    this.store = store;
    this.inbox = path.join(ipc, 'activity-queries');
    this.output = path.join(ipc, 'activity-view.json');
    this.overview = path.join(ipc, 'activity-overview.json');
    fs.mkdirSync(this.inbox, {recursive:true});
    this.views = new Map();
  }

  poll() {
    for (const name of fs.readdirSync(this.inbox).filter(entry => /^[a-f0-9-]{36}\.json$/i.test(entry))) {
      const file = path.join(this.inbox, name);
      let query;
      try { query = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (error) {
        if (error.code) throw error;
      }
      fs.unlinkSync(file);
      if (!query || !uuid.test(query.view) || !Number.isSafeInteger(query.serial) ||
          !Number.isSafeInteger(query.limit) || query.limit < 1 || (query.focus !== null && !uuid.test(query.focus))) continue;
      const channel=query.channel??'conversation';
      const session=query.session??null;
      if((channel!=='conversation'&&channel!=='overview')||
         (session!==null&&(typeof session!=='string'||!/^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$/.test(session))))continue;
      const state=this.views.get(channel)??{query:null,published:null,first:null};
      if(state.query?.view!==query.view||query.serial>state.query.serial)state.query={...query,session};
      this.views.set(channel,state);
    }
    for(const [channel,state] of this.views)this.publish(channel,state);
  }

  publish(channel,state) {
    const {view,serial,limit,focus,session}=state.query;
    const current=state.published;
    const sameView=current?.view===view&&current.session===session;
    const revision = this.store.revision;
    if(sameView&&current.serial===serial&&current.revision===revision)return;
    const {first,items,older,answer}=this.store.page({first:sameView?state.first:null,
      limit,previousLimit:sameView?current.limit:limit,focus,session,managedOnly:channel==='overview'});
    const output=channel==='overview'?this.overview:this.output;
    const temp=output+'.tmp';
    fs.writeFileSync(temp,JSON.stringify({view,serial,limit,focus,session,items,older,answer}));
    replaceFileSync(temp,output);
    state.first=first;
    state.published={view,serial,limit,session,revision};
  }
}
