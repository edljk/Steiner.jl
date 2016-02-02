module Steiner

using Base.LinAlg, Gadfly, NearestNeighbors, MAT
using CPLEX, MathProgBase, Gurobi
using GeneralTools, GraphicTools, MeshTools, ColorsTools

export steinerLP, steinerCPLEX


#----------------------------------------------------------
function steinerCPLEX(np::Int64=400,steinertype::Int64=1;
                      nearestk::Int64=20,dim::Int64=2,npt::Int64=4,savedata::Bool=false)

    Main.closeall();
    # for nn = 3:10 Steiner.steinerCPLEX(500,3,npt=nn,dim=2,nearestk=50,savedata=true) end
    # for nn = 3:8 Steiner.steinerCPLEX(500,3,npt=nn,dim=2) end
    targetp, npt = define_targets(dim,npt)

    # Mesh
    # 1 <-> delaunay of random points in [-1,1]
    # 2 <-> Nearest neighbor type  [-1,1]
    # 3 <-> Nearest neighbor on a grid of [-1,1]
    p, e, np, ne = gensteiner_mesh(steinertype,targetp,np,nearestk=nearestk,dim=dim)
    l = sqrt(sum((p[e[:,1],:]- p[e[:,2],:]).^2, 2))
    #plot_graph(p,e,ones(size(e,1)),figure=1);plot_points(targetp[:,1:dim],(0.5,0.,0.),scales=0.08,figure=1);view2D()

    A = []; Amaxmin = []
    for k = 1:npt
        IG = sub2ind((ne,npt+2),1:ne,repmat([k,],ne))
        if k==1
            A = sparse(e[:,1], IG,  ones(ne), np, ne*(npt+2)) + 
                sparse(e[:,2], IG, -ones(ne), np, ne*(npt+2))
        else
            A = vcat(A,sparse(e[:,1], IG,  ones(ne), np, ne*(npt+2)) + 
                       sparse(e[:,2], IG, -ones(ne), np, ne*(npt+2)))
        end
    end
    # add inequalities for max/min corresponding to variables t/s
    IGt = sub2ind((ne,npt+2),1:ne,repmat([npt+1,],ne))
    IGs = sub2ind((ne,npt+2),1:ne,repmat([npt+2,],ne))
    for k = 1:npt
        IG = sub2ind((ne,npt+2),1:ne,repmat([k,],ne))        
        if k==1
            Amaxmin = sparse(1:ne,IG,ones(ne),ne,ne*(npt+2)) + sparse(1:ne,IGt,-ones(ne),ne,ne*(npt+2))
        else
            Amaxmin = vcat(Amaxmin,sparse(1:ne,IG,ones(ne),ne,ne*(npt+2)) + sparse(1:ne,IGt,-ones(ne),ne,ne*(npt+2)))
        end
        Amaxmin = vcat(Amaxmin,sparse(1:ne,IG,-ones(ne),ne,ne*(npt+2)) +  sparse(1:ne,IGs,ones(ne),ne,ne*(npt+2)))
    end      
    # Dirichlet condition
    targets = (np-size(targetp,1)+1):np
    b = zeros(np,npt); b[targets,:] = eye(size(targetp,1))
    b[end,:] = -ones(1,npt); b[end,end] = 0 # sink
    b = b[:]

    # vcost
    cc = hcat(zeros(1,npt*ne),l[:,1]',-l[:,1]')

   
    # call CPLEX/Gurobi
    solver = CplexSolver(CPX_PARAM_LPMETHOD=6,CPX_PARAM_SCRIND=1,CPX_PARAM_SIMDISPLAY=1)
    solver = GurobiSolver(DisplayInterval=10,Crossover=0)
    sol = linprog(cc[1,:],vcat(A,Amaxmin),'<',vcat(b,zeros(size(Amaxmin,1)))[:,1],-Inf, Inf, solver)
    objval = sol.objval
    u = sol.sol
    
    # display
    feas = sqrt(sum((A*u-b).^2,2))[1]
    @printf "feas            = %4.6f\n"  feas
    println("objv            = "*InOrange*"$(objval)"*InDefault)
    t = u[(ne*npt+1):(ne*(npt+1))]
    s = u[(ne*(npt+1)+1):end]
    displaysave_steinertree(t,s,e,p,targetp,1,savedata)
   
    
    # display sizes
    println("np              = "*InBlue*string(np)*InDefault)
    println("ne              = "*InBlue*string(ne)*InDefault)
    println("dims of A       = "*InBlue*string(size(A))*InDefault)
    println("dims of Amaxmin = "*InBlue*string(size(Amaxmin))*InDefault)
    println("dims of c       = "*InBlue*string(length(cc))*InDefault)
    println("dims of btot    = "*InBlue*string(length(vcat(b,zeros(size(Amaxmin,1)))))*InDefault)

end



#----------------------------------------------------------
function steinerLP(maxiter::Int64=10000,np::Int64=400)

    # Target points
    Main.closeall(); npt = 4;dim = 2
    tt = linspace(0.,2*pi,npt+1)[1:(end-1)]
    targetp = hcat(cos(tt),sin(tt),zeros(npt))*.95
    
    # Mesh
    steinertype = 1 # 1 <-> delaunay of random points in [-1,1]
                    # 2 <-> Nearest neighbor type  [-1,1]
                    # 3 <-> Nearest neighbor on a grid of [-1,1]
    p, e, np, ne = gensteiner_mesh(steinertype,targetp,np,nearestk=8)
    l = sqrt(sum((p[e[:,1],:]- p[e[:,2],:]).^2, 2))
    #plot_graph(p,e,ones(size(e,1)),figure=1);plot_points(targetp[:,1:dim],(0.5,0.,0.),scales=0.08,figure=1);view2D()
    
    # divergence matrix
    A = sparse(e[:,1], collect(1:ne),  ones(ne), np, ne) + 
    sparse(e[:,2], collect(1:ne), -ones(ne), np, ne)
    L = hcat(speye(ne,ne),-speye(ne,ne))
    b = zeros(np,npt); Ap = A'; Lp = L'
    
    # Dirichlet condition
    targets = (np-size(targetp,1)+1):np
    b[targets,:] = eye(size(targetp,1))
    b[end,:] = -ones(1,npt); b[end,end] = 0 # sink

    # parameters
    Lip = 5; tau = 0.1/Lip; sigma = 1/tau/Lip^2

    # memory allocation
    u = zeros(ne, npt);s = zeros(ne,1); t = zeros(ne,1)     # primals
    psi = zeros(ne,npt); phi = zeros(ne,npt);xi = zeros(np,npt) # duals
    psi_ = copy(psi); phi_ = copy(phi); xi_ = copy(xi)
    prodAtmp = zeros(size(A,1)); prodAptmp = zeros(size(A,2))
    prodLtmp_T = zeros(size(L,1));prodLtmp_S = zeros(size(L,1))
    prodLptmp_T = zeros(size(L,2));prodLptmp_S = zeros(size(L,2))
    uS = copy(vcat(u[:,1],s)); uT = copy(vcat(u[:,1],t))

    for iter = 1:maxiter
        copy!(psi_,psi); copy!(phi_,phi); copy!(xi_,xi)
        #psi_ = copy(psi); phi_ = copy(phi); xi_ = copy(xi)  
        for j = 1:npt
            psi[:,j] = max(0, psi[:,j] + sigma*(L*vcat(u[:,j],s)))
            phi[:,j] = min(0, phi[:,j] + sigma*(L*vcat(u[:,j],t)))
            xi[:,j] = xi[:,j] + sigma*(A*u[:,j] - b[:,j])
        end
        psi_ = copy(2*psi - psi_); phi_ = copy(2*phi - phi_); xi_ = copy(2*xi - xi_)
        for j = 1:npt
            tmp_s = L'*psi_[:,j]
            tmp_t = L'*phi_[:,j]
    
            u[:,j] = u[:,j] - tau*(tmp_s[1:ne] + tmp_t[1:ne] + A'*xi_[:,j])
            s = s - tau*(l + tmp_s[ne+1:end])
            t = t - tau*(-l + tmp_t[ne+1:end])
        end


        # display
        if mod(iter,1000)==0
            feas = sqrt(sum((A*u-b).^2,2))[1]
            @printf "iter = %04d, feas = %4.6f\n" iter feas
            #displaysave_steinertree(s[:,1],t[:,1],e,p,targetp,1)
            ve = 1 - max(0,s-t)
            minmaxmean(ve)
            Ie = find(x->x>0.1,ve)
            mlab.figure(2);mlab.clf();vec = plot_graph(p,e[Ie,:],1-ve[Ie,1],figure=2);view2D();setcolormap(vec,"Oranges")
            plot_points(targetp[:,1:dim],(0.5,0.,0.),scales=0.08,figure=2)
        end
    end
end


#----------------------------------------------------------
function gensteiner_mesh(steinertype::Int64=1,targetp::Array{Float64,2}=zeros(1,3),np::Int64=400;
                         dim::Int64=2,nearestk::Int64=30)
    
    if steinertype==1 # 1 <-> delaunay of random points in [-1,1]
        p = vcat(2.*rand(np-size(targetp,1),dim)-1,targetp[:,1:dim])
        tri = delaunay(p)
        ep = convert(Array{Int64,2},vcat(tri[:,[1,2]],tri[:,[2,3]],tri[:,[1,3]]))
    elseif steinertype==2 # 2 <-> Nearest neighbor type  [-1,1]
        p = vcat(2*rand(np-size(targetp,1),dim)-1,targetp[:,1:dim])
        tree = KDTree(p[:,1:dim]',Euclidean();leafsize=2)
        println(tree)
        dists = zeros(size(p,1),nearestk)
        idxs = zeros(Int64,size(p,1),nearestk)
        ep = zeros(Int64,size(p,1)*nearestk,2)
        for k = 1:size(p,1)
            idxst, distst = knn(tree,p[k,1:dim],nearestk)
            ep[((k-1)*nearestk+1):k*nearestk,1] = k
            ep[((k-1)*nearestk+1):k*nearestk,2] = idxst
            #println(idxst,"\n",distst)
        end
    elseif steinertype==3 # 3 <-> Nearest neighbor on a grid of [-1,1]
        npg = Int64(max(ceil(np^(1./dim)),5)); xx = linspace(-1,1,npg)
        if dim==2
            X, Y = Main.ndgrid(xx,xx)
            Z =zeros(size(X))
        else
            X, Y, Z = Main.ndgrid(xx,xx,xx)
        end
        pts = hcat(X[:],Y[:],Z[:]); pts = pts + (2.*rand(size(pts))-1.)/10000.
        p = vcat(pts[:,1:dim],targetp[:,1:dim])
        tree = KDTree(p[:,1:dim]',Euclidean();leafsize=2)
        println(tree)
        dists = zeros(size(p,1),nearestk)
        idxs = zeros(Int64,size(p,1),nearestk)
        ep = zeros(Int64,size(p,1)*nearestk,2)
        for k = 1:size(p,1)
            idxst, distst = knn(tree,p[k,1:dim],nearestk)
            ep[((k-1)*nearestk+1):k*nearestk,1] = k
            ep[((k-1)*nearestk+1):k*nearestk,2] = idxst
            #println(idxst,"\n",distst)
        end
    end
    ep = uniquerows(sort(ep,2))[1]
    em = hcat(ep[:,2],ep[:,1]); e = vcat(ep,em); 
    np = size(p,1);  ne = size(e,1)
    return p, e, np, ne
end

#----------------------------------------------------------
function define_targets(dim::Int64=2,npt::Int64=4)
    # Target points
    if dim==2
        tt = linspace(0.,2*pi,npt+1)[1:(end-1)]
        targetp = hcat(cos(tt),sin(tt),zeros(npt))*.95
        if npt>8
            targetp = 2*rand(npt,2) - 1.
        end
    elseif dim==3
        ST, FT, SH, FH, SO, FO, SD, FD, SI, FI = polyedres()
        if npt==4
            targetp = ST           
        elseif npt==8
            targetp = SH           
        end   
    end
    targetp = targetp - repmat(mean(targetp,1),size(targetp,1),1)
    targetp = 0.9*targetp/maximum(abs(targetp))
    return targetp, size(targetp,1)
end

#----------------------------------------------------------
function displaysave_steinertree(t::Array{Float64,1},s::Array{Float64,1},e::Array{Int64,2},
                                 p::Array{Float64,2},targetp::Array{Float64,2},fignum::Int64,savedata::Bool)
    dim = size(p,2); np = size(p,1); npt = size(targetp,1); ve = 1 - max(0,t-s)
    mlab.figure(fignum);mlab.clf();
    vec1 = plot_graph(p,e,ve,figure=fignum,line_width=1.2,color=(0.9,0.3,0.))
    esm = Int64(size(e,1)/2); ep = e[1:esm,:]; ve = min(ve[1:esm],ve[(esm+1):end]);Ie = find(x->x<0.1,ve)
    minmaxmean(ve)
    println(InOrange*string(unique(round(ve*1e3)/1000))*InDefault)
    vec2 = plot_graph(p,ep[Ie,:],ve[Ie,1],figure=fignum,line_width=5.,vmin=0.,vmax=1.);view2D();setcolormap(vec2,"Oranges")
    plot_points(targetp[:,1:dim],(0.5,0.,0.),scales=0.08,figure=fignum);mlab.colorbar()

    # save
    if savedata
        filename = ENV["HOME"]*"/Julia/Steiner/pictures/fig"*"_dim_"*string(dim)*"_np_"*string(np)*"_nps_"*string(npt)
        println(InMagenta*filename*InDefault)
        mlab.savefig(filename*".png",size=(2000,2000))
        matwrite(replace(filename,"pictures","runs")*".mat",Dict("t"=>t,"s"=>s,"p"=>p,"e"=>e,"targetp"=>targetp))
    end
end

end # module







