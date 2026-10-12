'use strict';
const {contextBridge,ipcRenderer}=require('electron');
contextBridge.exposeInMainWorld('qq',{request:(command,args={})=>ipcRenderer.invoke('qq:operation',command,args),onState:callback=>{const f=(_e,state)=>callback(state);ipcRenderer.on('qq:state',f);return ()=>ipcRenderer.removeListener('qq:state',f);},onSuccess:callback=>ipcRenderer.on('qq:success',()=>callback()),onTheme:callback=>ipcRenderer.on('qq:theme',(_e,dark)=>callback(dark))});
