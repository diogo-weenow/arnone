({
  aoAtualizarSessao: function (component, event, helper) {
    var tipo = event.getParams().changeType;
    if (tipo === "LOADED" || tipo === "CHANGED") {
      helper.abrirLead(component);
    }
  }
});