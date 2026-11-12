({
  abrirLead: function (component) {
    var sessao = component.get("v.sessao");
    if (!sessao || sessao.Status !== "Active") {
      return;
    }
    var leadId = this.leadDaSessao(sessao);
    if (!leadId || component.get("v.leadAberto") === leadId) {
      return;
    }

    var workspace = component.find("workspace");
    var self = this;
    workspace
      .isConsoleNavigation()
      .then(function (emConsole) {
        return emConsole ? workspace.getEnclosingTabId() : null;
      })
      .then(function (tabId) {
        return tabId ? workspace.getTabInfo({ tabId: tabId }) : null;
      })
      .then(function (aba) {
        if (!aba) {
          return null;
        }
        // Subaba da conversa: o Lead abre ao lado dela, sob a mesma aba principal.
        var principal = aba.isSubtab ? aba.parentTabId : aba.tabId;
        return workspace.getTabInfo({ tabId: principal });
      })
      .then(function (principal) {
        if (!principal) {
          return null;
        }
        component.set("v.leadAberto", leadId);
        if (self.jaAberto(principal, leadId)) {
          return null;
        }
        return workspace.openSubtab({
          parentTabId: principal.tabId,
          recordId: leadId,
          focus: false
        });
      })
      .catch(function (erro) {
        console.error("STE_AbrirLeadDaSessao: não abriu o Lead", erro);
      });
  },

  /** Lead da sessão; sem ele, o vínculo do MessagingEndUser. */
  leadDaSessao: function (sessao) {
    if (sessao.LeadId) {
      return sessao.LeadId;
    }
    return sessao.MessagingEndUser ? sessao.MessagingEndUser.LeadId : null;
  },

  /** Compara pelos 15 primeiros caracteres: a aba pode guardar o Id curto. */
  jaAberto: function (principal, leadId) {
    var alvo = leadId.substring(0, 15);
    var abas = [principal].concat(principal.subtabs || []);
    return abas.some(function (aba) {
      return aba.recordId && aba.recordId.substring(0, 15) === alvo;
    });
  }
});